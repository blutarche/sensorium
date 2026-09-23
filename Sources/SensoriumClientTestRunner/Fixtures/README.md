# H.264 decoder fixture

`h264-sample.bin` is six access units of 320x200 flat-colour video, encoded
at H.264 Main profile, the profile the Sensorium host encodes at, in exactly
the shape the Sensorium wire carries: raw SPS and PPS parameter sets delivered out
of band, and access units whose NAL units are prefixed with a four-byte big
endian length rather than Annex B start codes. The file is the SPS bytes, then
the PPS bytes, then each access unit end to end; `h264-sample.json` gives the
frame size, the length of each of those pieces, and which access units are key
frames, so a test can slice the blob without parsing H.264. Key frames are the
first and the fourth access unit, so a decoder can be reset between two of
them. It was produced by encoding six generated frames at 320x200 with a
forced key frame at those two positions and writing the encoder's own output
unchanged; nothing about it is platform specific once written, and it is small
enough to read in full.
