#!/usr/local/bin/bash
set -e

mkdir -p work

dl() {
  # Download libgen DB
  BASE_URL=http://gen.lib.rus.ec/dbdumps/
  URL="$BASE_URL/libgen_compact_$(date '+%Y-%m-%d').rar"
  wget -O work/libgen.rar "$URL"
}

unpack() {
  cd work
  unrar x libgen.rar
}

convert_to_sqlite() {
  # mysql2sqlite generates syntactically invalid sqlite3 dump, but it won't hurt
  # the main table with the books, so we can ignore the exit code.
  ./mysql2sqlite work/backup_ba.sql | sqlite3 work/libgen.db || :
}

find_indices() {
  # Torrents are bundled into 1000s, so find those 1000s
  sqlite3 work/libgen.db 'SELECT DISTINCT(id/1000) FROM updated WHERE extension="chm" ORDER BY id COLLATE NOCASE' > work/ids
}

get_torrent_files() {
  mkdir -p work/torrents
  while read -r id; do
    case "$id" in
      0)
        # Special-cased first archive
        id=;;
      82)
        # Missing archive
        continue;;
    esac
    wget http://gen.lib.rus.ec/repository_torrent/r_${id}000.torrent -O work/torrents/r_${id}000.torrent || echo "Missing archive $id" >> missing
  done < work/ids
}

dl_torrent_files() {
  mkdir -p work/downloads
  while read -r id; do
    case "$id" in
      0)
        # Special-cased first archive
        torrent_file=r_000.torrent
        torrent_name=0
        ;;
      82)
        # Missing archive
        continue;;
      *)
        torrent_file=r_${id}000.torrent
        torrent_name=${id}000
    esac
    from_id=${id}000
    to_id=$((id+1))000
    sql="
SELECT id,LOWER(md5) FROM updated
WHERE extension=\"chm\"
  AND id>=$from_id
  AND id<$to_id
COLLATE NOCASE
"
    transmission-remote \
      --start-paused --no-trash-torrent \
      --download-dir="$PWD/work/downloads" --add "work/torrents/$torrent_file"
    torrent_id=$(transmission-remote --list | grep " $torrent_name\$" | awk '{print $1}')
    unset files
    echo "${files[@]}"
    declare -A files
    while read -r file_id file_md5; do
      files["$file_md5"]="$file_id"
    done < <(transmission-remote -t "$torrent_id" -f | grep -v 'Done' | grep -v 'files)' | sed -e 's@:.*/@ @')
    while read -r id md5; do
      unset files["$md5"]
    done < <(sqlite3 work/libgen.db '.mode tabs' "$sql")
    echo "${files[@]}"
    R=""
    for id in ${files[@]}; do
      if [ -n "$R" ]; then
        R="$R,$id"
      else
        R="$id"
      fi
    done
    echo "$torrent_name $torrent_id -G $R"
    transmission-remote -t "$torrent_id" -G "$R"
    transmission-remote -t "$torrent_id" --start
  done < work/ids
}

for op in "$@"; do
  $op
done
