# Focus pixel maps

The `80000331_*.fpm.gz` files (Canon EOS M, camera id 0x80000331) are the
`.fpm` focus pixel maps from MLV App, gzip-compressed (`gzip -9 -n`); the
file names are otherwise unchanged.

- Source: https://github.com/ilia3101/MLV-App, `pixel_maps/` at commit
  d1c892134d5f00ec513847bc1730f3743410fea6
- License: GPL-3.0 (MLV App)
- Focus pixel map work by Daniel Fort and the Magic Lantern community.

Format: one `x y` pair per line in raw-buffer coordinates, optional
`#FPM <camera id>` header. File name: `<camera id hex>_<raw width>x<raw height>.fpm`,
where the raw size is the RAWI `raw_info.width x raw_info.height` of the clip.
