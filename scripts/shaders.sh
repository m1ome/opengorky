#!/bin/sh
# The viewer's GPU shaders (src/viewer/gpu/shaders/*.vert, *.frag, GLSL 450) into what SDL
# GPU takes: SPIR-V (Vulkan) and MSL (Metal), written next to them and committed, so a
# build needs neither tool. Run after editing a shader; needs glslc (shaderc) and
# spirv-cross (brew install shaderc spirv-cross).
set -e
cd "$(dirname "$0")/../src/viewer/gpu/shaders"
for f in *.vert *.frag *.comp; do
  glslc -O --target-env=vulkan1.0 "$f" -o "$f.spv"
  # MSL: bindings as SDL's [[buffer]] order wants them (the shaders shift their storage
  # buffers under -DMSL), the decoration's index taken as is.
  glslc -O --target-env=vulkan1.0 -DMSL "$f" -o "$f.msl.spv"
  spirv-cross --msl --msl-version 20100 --msl-decoration-binding "$f.msl.spv" --output "$f.msl"
  rm "$f.msl.spv"
done
echo "shaders: $(ls *.spv | wc -l | tr -d ' ') compiled"
