# bin/tinymix

Statically linked `aarch64` build of upstream tinyalsa's `tinymix`, bundled
because the CMF Phone 1 does not ship one and mixer controls cannot be read or
written without it.

- upstream: https://github.com/tinyalsa/tinyalsa
- commit:   9fab97ca07184371ecad81154d1dadb09d0fa7cf
- license:  BSD-3-Clause, see TINYALSA-LICENSE

Built with:

```sh
git clone https://github.com/tinyalsa/tinyalsa && cd tinyalsa
git checkout 9fab97ca07184371ecad81154d1dadb09d0fa7cf
aarch64-linux-gnu-gcc -static -O2 -Wall -Iinclude \
    src/mixer.c src/mixer_hw.c src/limits.c utils/tinymix.c -o tinymix
aarch64-linux-gnu-strip tinymix
```

Only the hardware mixer backend is compiled in; the plugin backend
(`TINYALSA_USES_PLUGINS`) is left out, so the binary needs no `dlopen` and
stays fully static.

Rebuild it yourself if you would rather not trust a shipped binary, and drop
the result at `/data/adb/cmf-stereo/bin/tinymix` — that path is searched
first.
