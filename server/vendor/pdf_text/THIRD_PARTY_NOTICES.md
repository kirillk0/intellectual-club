# Third-party notices

`lib/pdf_text/{glyph_name,text_encoding,glyph_name_validator}.ex` are adapted
from native_elixir_pdf_utilities 1.1.0, by Cees Kettenis:
https://github.com/Cees-Kettenis/native_elixir_pdf_utilities

Changes: module namespace only. No HTML, writer, renderer, application,
resvg dependency, reader or worker code is included. All other modules are
new implementations informed by the PDF specification and the local research.

## native_elixir_pdf_utilities license

MIT License

Copyright (c) 2025 Cees Kettenis

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

## Adobe glyph data

The Adobe BSD-style notice is retained in full at the beginning of
`lib/pdf_text/glyph_name.ex` and applies to its glyph-name assignments.

### Adobe notice (also for binary distributions)

```text
The glyph-name assignments follow the Adobe Glyph List and ITC Zapf Dingbats
Glyph List. The Elixir lookup and decoding implementation is maintained here.

Copyright 2002-2019 Adobe (http://www.adobe.com/).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of Adobe nor the names of its contributors may be used to
   endorse or promote products derived from this software without specific
   prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

```

### Original source SHA-256

- `lib/pdf/glyph_name.ex`: `2ace68de20201e72c6a6c54bdf10aa7c3eb37500bfdd7e65c39c1f6d031b7754`
- `lib/pdf/text_encoding.ex`: `96d24a987fd35483fba8f9ba72688d36daa77b2b9501831b09337ba4cfbeef14`
- `lib/validators/glyph_name_validator.ex`: `6f4c526b0ec65476a41a5864c6c00bd83a5abed41a7859bc3431064e4e4d8b6a`
