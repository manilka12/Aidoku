# Upscaling Models for Aidoku

This directory contains CoreML models used by Aidoku's image upscaling feature.

## Available Models

### Waifu2x Models
- `waifu2x_noise0_scale2x.mlmodel`: Waifu2x with no noise reduction, scale 2x
- `waifu2x_noise1_scale2x.mlmodel`: Waifu2x with low noise reduction, scale 2x
- `waifu2x_noise2_scale2x.mlmodel`: Waifu2x with medium noise reduction, scale 2x
- `waifu2x_noise3_scale2x.mlmodel`: Waifu2x with high noise reduction, scale 2x

### ESRGAN Models
- `esrgan_scale2x.mlmodel`: ESRGAN with scale 2x

## How to Add Models

1. Download pre-trained models from the [waifu2x-ios](https://github.com/imxieyi/waifu2x-ios) or [UppScale](https://github.com/pavlovskyive/UppScale) repositories
2. Convert the models to CoreML format if needed
3. Place them in this directory with the naming convention shown above
4. Add the models to the Xcode project by dragging them into the Resources group

## Model Conversion

For instructions on converting models to CoreML format, refer to:
- [Apple's CoreML Tools](https://coremltools.readme.io/docs)
- [waifu2x-ios conversion guide](https://github.com/imxieyi/waifu2x-ios#about-models)

## Notes

- The upscaling feature will automatically use these models based on the user's settings
- If a model is not available, the feature will gracefully fall back to a simpler model or no upscaling
- Models are quite large, so they are not included in the repository by default