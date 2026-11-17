# Third-party notices

VocalCord's own code is under the [PolyForm Noncommercial License 1.0.0](LICENSE.md).
It uses the components below, each under its own licence.

## In the app

| Component | Licence | Notes |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20 | MIT | Copyright (c) 2019-2026 Miguel de Icaza; (c) 2017-2019 the xterm.js authors; (c) 2014-2016 SourceLair Private Company. Compiled into VocalCord. |
| [uv](https://github.com/astral-sh/uv) 0.13.7 | MIT or Apache-2.0 | Copyright (c) 2025 Astral Software Inc. Shipped unmodified inside VocalCord.app to install the engine. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.8 | Apache-2.0 | Fetched at build time as a dependency of SwiftTerm's own tools; not part of VocalCord. |

## Downloaded on first run

VocalCord does not ship these. On first run, uv downloads Python and the engine's
packages from PyPI, and the engine downloads the models from Hugging Face.

### Models

| Model | Licence | Notes |
|---|---|---|
| [Breeze TTS 2](https://huggingface.co/BreezeBlue/Breeze-TTS-2), MLX [4-bit](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-4bit) and [8-bit](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-8bit) builds by mlx-community | BreezeBlue Research and Non-Commercial License Agreement 1.0 | Research and non-commercial use only, outputs included. Do not clone a real person's voice without their consent. "Breeze TTS 2 is licensed under the BreezeBlue Research and Non-Commercial License Agreement. Copyright (c) 2026 RESONIA, INC. All Rights Reserved." |
| [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) by OpenAI, [MLX 8-bit build](https://huggingface.co/mlx-community/whisper-large-v3-turbo-asr-8bit) by mlx-community | MIT | Copyright (c) 2022 OpenAI. |
| [WeSpeaker ResNet34-LM](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM) (`voxceleb_resnet34_LM.onnx`) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Speaker model by the [WeSpeaker](https://github.com/wenet-e2e/wespeaker) project, trained on VoxCeleb2. Used unmodified for the "Sounds like you" score. |
| [UTMOS22 strong, ONNX export](https://huggingface.co/TigreGotico/utmos-onnx) by TigreGotico | MIT | Exported from [tarepan/SpeechMOS](https://github.com/tarepan/SpeechMOS) (MIT, Copyright (c) 2023 tarepan), itself from [sarulab-speech/UTMOS22](https://github.com/sarulab-speech/UTMOS22) (MIT, Copyright (c) 2022 Saruwatari & Koyama laboratory, The University of Tokyo). |

### Engine software

| Component | Licence | Notes |
|---|---|---|
| Python 3.13 | PSF License 2.0 | The [python-build-standalone](https://github.com/astral-sh/python-build-standalone) build that uv installs. |
| [mlx](https://github.com/ml-explore/mlx) | MIT | Copyright (c) 2023 Apple Inc. |
| [mlx-audio](https://github.com/Neywa-Labs/mlx-audio) | MIT | Copyright (c) 2024 Prince Canuma. |
| [onnxruntime](https://github.com/microsoft/onnxruntime) | MIT | Copyright (c) Microsoft Corporation. |
| [kaldi-native-fbank](https://github.com/csukuangfj/kaldi-native-fbank) | Apache-2.0 | |
| [imageio-ffmpeg](https://github.com/imageio/imageio-ffmpeg) | BSD-2-Clause | Copyright (c) 2019-2025, imageio. |
| ffmpeg 9.0, inside the imageio-ffmpeg wheel | GPL-2.0-or-later | The [osxexperts.net](https://www.osxexperts.net/) build, configured with `--enable-gpl`. Used only when the Mac has no ffmpeg of its own; VocalCord runs it as a separate program. Source: [ffmpeg.org](https://ffmpeg.org/download.html). |

### Other Python packages

The rest of [`engine/requirements.txt`](engine/requirements.txt), with the licence each declares:
annotated-doc (MIT), annotated-types (MIT), anyio (MIT), cffi (MIT-0), click (BSD-3-Clause),
filelock (MIT), flatbuffers (Apache-2.0), fsspec (BSD-3-Clause), h11 (MIT), hf-xet (Apache-2.0),
httpcore2 (BSD-3-Clause), httpx2 (BSD-3-Clause), huggingface_hub (Apache-2.0), idna (BSD-3-Clause),
iniconfig (MIT), Jinja2 (BSD-3-Clause), markdown-it-py (MIT), MarkupSafe (BSD-3-Clause), mdurl (MIT),
miniaudio (MIT), mlx-metal (MIT), numpy (BSD-3-Clause, with parts under 0BSD, MIT, Zlib and CC0-1.0),
packaging (Apache-2.0 or BSD-2-Clause), pluggy (MIT), protobuf (BSD-3-Clause), pycparser (BSD-3-Clause),
Pygments (BSD-2-Clause), pytest (MIT), PyYAML (MIT), regex (Apache-2.0 and CNRI-Python), rich (MIT),
safetensors (Apache-2.0), scipy (BSD-3-Clause; its wheel includes the GCC runtime libraries, GPL-3.0
with the GCC Runtime Library Exception), sentencepiece (Apache-2.0), shellingham (ISC),
sounddevice (MIT; includes PortAudio, MIT), soundfile (BSD-3-Clause; includes libsndfile, LGPL-2.1),
tokenizers (Apache-2.0), tqdm (MPL-2.0 and MIT), transformers (Apache-2.0), truststore (MIT),
typer (MIT), typing-inspection (MIT), typing_extensions (PSF-2.0).
