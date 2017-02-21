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
height=64;
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

[ -d data/imgs -a -s data/htr/lang/word/te.txt -a \
  -s data/htr/lang/word/tr.txt -a -s data/htr/lang/word/va.txt -a \
  -s data/kws/lang/word/te.txt -a -s data/kws/lang/word/tr.txt -a \
  -s data/kws/lang/word/va.txt ] || \
  ( echo "The IAM database is not available!">&2 && exit 1; );

function tokenize_char () {
  # The original transcriptions may contain some contractions already
  # splitted (e.g. he 's), merge those contractions in order to avoid
  # artificial whitespaces.
  # Singleton grave accents (`) are subtituted by a single quote ('),
  # since this character is not present in IAM train/valid.
  # Double quotes (") are replaced by a pair of single quotes (''), to
  # avoid graphical ambiguity.
  # Token <space> is used to mark whitespaces between words.
  # Also, replace # by <stroke>.
  with_id=0;
  [ "$1" = "--with-id" ] && with_id=1;
  sed 's/ '\''\(s\|d\|ll\|m\|ve\|t\|re\|S\|D\|LL\|M\|VE\|T\|RE\)\b/'\''\1/g' |
  awk -v WID=$with_id '{
      start=1;
      if (WID) { printf("%s", $1); start=2; }
      for(i=start;i<=NF;++i) {
        for(j=1;j<=length($i);++j)
          printf(" %s", substr($i, j, 1));
        if (i < NF) printf(" <space>");
      }
      printf("\n");
    }' |
  tr \` \' |
  sed 's/"/'\'' '\''/g;s/#/<stroke>/g;s/^[ ]\+//g; s/[ ]\+$//g'
}

for c in htr kws; do
  mkdir -p data/$c/lang/char;

  for p in te tr va; do
    # Place all character-level transcriptions into a single txt table file.

    [ -s data/$c/lang/char/$p.txt -a $overwrite = false ] && continue;
    cat data/$c/lang/word/$p.txt |
    tokenize_char --with-id > data/$c/lang/char/$p.txt;
  done;

  # Generate symbols table from training and valid characters.
  # This table will be used to convert characters to integers by Kaldi and the
  # CNN + RNN + CTC code.
  [ -s data/$c/lang/char/symbs.txt -a $overwrite = false ] || (
    for p in tr va; do
      cut -f 2- -d\  data/$c/lang/char/$p.txt | tr \  \\n;
    done | sort -u -V |
    awk 'BEGIN{
      N=0;
      printf("%-12s %d\n", "<eps>", N++);
      printf("%-12s %d\n", "<ctc>", N++);
    }NF==1{
      printf("%-12s %d\n", $1, N++);
    }' > data/$c/lang/char/symbs.txt;
  )
  wc -l data/$c/lang/char/symbs.txt | awk '{
    printf("Number of training symbols in \"%s\" = %d\n", $2, $1 - 1);
  }' >&2;
done;

## Prepare external corpora data
for c in brown lob_excludealltestsets wellington; do
  [ -f data/htr/lang/char/$c.txt -a $overwrite = false ] ||
  cat data/lm/$c.txt | tokenize_char > data/htr/lang/char/$c.txt
done;

## Enhance images with Mauricio's tool, crop image white borders and resize
## to a fixed height.
mkdir -p data/imgs_proc;
TMPD="$(mktemp -d)";
bkg_pids=();
np="$(nproc)";
for f in $(awk '{print $1}' data/{htr,kws}/lang/word/{tr,te,va}.txt | sort -u); do
  [ -f data/imgs_proc/$f.jpg -a "$overwrite" = false ] && continue;
  [ ! -f data/imgs/$f.png ] && \
    echo "Image data/imgs/$f.png is not available!">&2 && exit 1;
  (
    echo "File data/imgs/$f.png..." >&2;
    imgtxtenh -u mm -d 118.1102362205 data/imgs/$f.png data/imgs_proc/$f.jpg;
    convert data/imgs_proc/$f.jpg -fuzz 5% -trim +repage data/imgs_proc/$f.jpg;
    convert data/imgs_proc/$f.jpg -resize "x$height" -strip data/imgs_proc/$f.jpg;
  ) &> "$TMPD/${#bkg_pids[@]}" &
  bkg_pids+=("$!");

  ## Wait for jobs to finish when number of running jobs = number of processors
  if [ "${#bkg_pids[@]}" -eq "$np" ]; then
    for n in $(seq 1 "${#bkg_pids[@]}"); do
      wait "${bkg_pids[n-1]}" || (
        echo "Failed image processing:" >&2 && cat "$TMPD/$[n-1]" >&2 && exit 1;
      );
    done;
    bkg_pids=();
  fi;
done;

## Wait for jobs to finish
for n in $(seq 1 "${#bkg_pids[@]}"); do
  wait "${bkg_pids[n-1]}" || (
    echo "Failed image processing:" >&2 && cat "$TMPD/$[n-1]" >&2 && exit 1;
  );
done;
bkg_pids=();
rm -rf "$TMPD";

for c in htr kws; do
  for p in te tr va; do
    awk '{print "data/imgs_proc/"$1".jpg"}' data/$c/lang/word/$p.txt \
      > data/$c/$p.lst;
  done
done;

exit 0;
