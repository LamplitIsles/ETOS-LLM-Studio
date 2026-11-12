# Synthetic opacity fixtures

These tiny images were created for this project from flat, synthetic colors;
they contain no third-party or user image content. `rgba-opaque.png` has an
alpha channel whose values are all 255; `rgba-transparent.png` differs by a
single alpha value of 254. `rgb.png`, JPEG and static WebP are opaque;
`transparent.webp` contains transparent pixels. The GIF, APNG and WebP files
contain multiple frames. `rgba16.png` exercises the conservative 16-bit PNG
fallback. PNG fixtures were made with ImageMagick and the RGBA pixel values
were generated with test-only pngjs; ImageMagick generated the other formats.
