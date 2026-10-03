# Baskı Maliyeti Hesaplayıcı

3D baskının filament, elektrik, makine yıpranması ve işçilik maliyetini tek yerde toplayan, satış fiyatı öneren ücretsiz web uygulaması.

- Site: https://withered-salad-dde8.arinozalp39.workers.dev
- Bambu Studio köprüsü: https://github.com/arinozalp39-svg/baski-maliyeti-kopru

## Yayınlama

`public/` klasörü sitenin kendisidir. Bu depo Cloudflare'deki Worker'a bağlıdır: `main` dalına her yüklemede Cloudflare `wrangler.jsonc`'yi okuyup `public/` klasörünü yayınlar.

## Dilimleme motorları

Site, STL/3MF modellerini tarayıcıda dilimlemek için şu motorların WebAssembly derlemelerini içerir (hepsi AGPL-3.0):

- [Bambu Studio](https://github.com/bambulab/BambuStudio) 02.07.01.62: `public/bbl/` (kaynak ve değişiklikler: `public/bbl/kaynak.zip`)
- [OrcaSlicer](https://github.com/SoftFever/OrcaSlicer) 2.4.2, [OrcaWasm](https://github.com/Hiosdra/OrcaWasm) derlemesi: `public/orca/`
- [CuraEngine](https://github.com/Ultimaker/CuraEngine), [cura-wasm](https://github.com/Cloud-CNC/cura-wasm)

Lisans bilgileri `public/bbl/` ve `public/orca/` içindeki LICENSE, NOTICE ve KAYNAK dosyalarındadır.
