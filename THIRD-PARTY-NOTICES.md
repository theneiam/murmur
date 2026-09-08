# Third-party notices

Murmur is released under the MIT License (see `LICENSE`). It incorporates or
depends on the following third-party software. The same information is shown
in the app under **About Murmur**.

## WhisperKit / Argmax OSS

Speech recognition is performed by WhisperKit, part of Argmax OSS
(<https://github.com/argmaxinc/argmax-oss-swift>), linked as a Swift package.

MIT License — Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### swift-transformers (portions, via Argmax OSS)

Portions of Argmax OSS (`Sources/ArgmaxCore/External`) are derived from
swift-transformers (<https://github.com/huggingface/swift-transformers>),
Copyright 2022 Hugging Face SAS, licensed under the Apache License,
Version 2.0 (<http://www.apache.org/licenses/LICENSE-2.0>). The full license
text and Argmax's modification notice are in the `NOTICES` file of the
Argmax OSS repository.

## OpenAI Whisper models

The speech models Murmur downloads (`argmaxinc/whisperkit-coreml` on
Hugging Face) are CoreML conversions of OpenAI's Whisper checkpoints
(<https://github.com/openai/whisper>).

MIT License — Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
