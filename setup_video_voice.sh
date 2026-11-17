#!/bin/sh
set -eu
cd "$(dirname "$0")"

PYTHON_BIN=${PYTHON_BIN:-python3.13}
"$PYTHON_BIN" -m venv .venv-video
. .venv-video/bin/activate
python -m pip install --upgrade pip

if [ ! -d vendor/LuxTTS/.git ]; then
    mkdir -p vendor
    git clone --depth 1 https://github.com/ysharma3501/LuxTTS.git vendor/LuxTTS
fi

python -m pip install -r vendor/LuxTTS/requirements.txt
python -m pip install --no-deps -e vendor/LuxTTS
python -c 'from zipvoice.luxvoice import LuxTTS; LuxTTS("YatharthS/LuxTTS", device="mps"); print("LuxTTS and its transcriber are downloaded and ready")'
