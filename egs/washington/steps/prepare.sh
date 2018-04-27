#!/bin/bash
set -e;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

overwrite=false;
height=120;
help_message="
Usage: ${0##*/} [options]

Options:
  --height     : (type = integer, default = $height)
                 Scale lines to have this height, keeping the aspect ratio
                 of the original image.
  --overwrite  : (type = boolean, default = $overwrite)
                 Overwrite previously created files.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;


imgdir="data/washingtondb-v1.0/data/line_images_normalized";

# Check required files
for f in data/washingtondb-v1.0/ground_truth/transcription.txt; do
  [ ! -s "$f" ] && echo "ERROR: Required file \"$f\" does not exist!" >&2 &&
  exit 1;
done;

mkdir -p data/lang/char;

# Obtain character-level transcriptions of ALL the dataset.
[[ "$overwrite" = false && -s data/lang/char/transcript.txt ]] ||
gawk '{
  x=$1; y=$2;
  gsub(/-/, " ", y);
  gsub(/\|/, " <space> ", y);
  print x, y;
}' data/washingtondb-v1.0/ground_truth/transcription.txt \
  > data/lang/char/transcript.txt;

# Obtain lexicon.
[[ "$overwrite" = false && -s data/lang/lexiconp.txt ]] ||
cut -d\  -f2- data/washingtondb-v1.0/ground_truth/transcription.txt |
tr \|  \\n | tr \- \  | sort | uniq |
gawk '{
  w = "";
  for (i=1;i<=NF;++i) {
    if ($i == "s_bl")      w = sprintf("%s(", w);
    else if ($i == "s_br") w = sprintf("%s)", w);
    else if ($i == "s_cm") w = sprintf("%s,", w);
    else if ($i == "s_et") w = sprintf("%sV", w);
    else if ($i == "s_lb") w = sprintf("%sL", w);
    else if ($i == "s_mi") w = sprintf("%s-", w);
    else if ($i == "s_pt") w = sprintf("%s.", w);
    else if ($i == "s_qo") w = sprintf("%s:", w);
    else if ($i == "s_qt") w = sprintf("%s'\''", w);
    else if ($i == "s_s")  w = sprintf("%ss", w);
    else if ($i == "s_sl") w = sprintf("%ssl", w);
    else if ($i == "s_sq") w = sprintf("%s;", w);
    else if (match($i, /^s_(.+)$/, A)) w = sprintf("%s%s", w, A[1]);
    else w = sprintf("%s%s", w, $i);
  }
  printf("%-20s 1.0    <space> %s\n", w, $0);
}' | sort > data/lang/lexiconp.txt;

# Get list of characters
[[ "$overwrite" = false && -s data/lang/char/syms.txt ]] ||
cut -d\  -f2- data/lang/char/transcript.txt | tr \  \\n | sort -uV |
gawk 'BEGIN{
  N = 0;
  printf("%-12s %d\n", "<eps>", N++);
  printf("%-12s %d\n", "<ctc>", N++);
  printf("%-12s %d\n", "<space>", N++);
}$1 !~ /<space>/{
  printf("%-12s %d\n", $1, N++);
}' > data/lang/char/syms.txt ||
exit 1;

# Create files for each cross-validation set.
for cv in cv1 cv2 cv3 cv4; do
  mkdir -p "data/lists/$cv" "data/lang/char/$cv";
  for p in train valid test; do
    # List of image files for each partition
    [[ "$overwrite" = false && -s "data/lists/$cv/${p:0:2}.txt" ]] ||
    sed -r 's|^(.+)$|data/imgproc/\1.jpg|g' \
      "data/washingtondb-v1.0/sets/$cv/$p.txt" \
      > "data/lists/$cv/${p:0:2}.txt" ||
    exit 1;
    # Transcript filess for each partition
    [[ "$overwrite" = false && -s "data/lang/char/$cv/${p:0:2}.txt" ]] ||
    gawk -v LF="data/washingtondb-v1.0/sets/$cv/$p.txt" \
      'BEGIN{ while((getline < LF) > 0) { L[$1]=1; } }($1 in L){ print; }' \
      "data/lang/char/transcript.txt" > "data/lang/char/$cv/${p:0:2}.txt" ||
    exit 1;
  done;
done;

# Resize images to the appropiate scale.
mkdir -p data/imgproc;
mapfile -t imgs <<< "$(find "$imgdir" -name "*.png")";
for f in "${imgs[@]}"; do
  o="data/imgproc/$(basename "$f" .png).jpg";
  [[ "$overwrite" = false && -s "$o" ]] ||
  convert "$f" -resize "x$height" "$o" ||
  exit 1;
done;

exit 0;
