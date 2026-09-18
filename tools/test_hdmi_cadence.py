import numpy as np
from hdmi_cadence import unpack, decode_band, calibrate, sample_line


def encoded(ident, pre=0xd3):
    code=bytes([pre,ident>>8,ident&255,(ident^65535)>>8,(ident^65535)&255,
                (ident>>8)^(ident&255)^pre^0x5a])
    return np.unpackbits(np.frombuffer(code,dtype=np.uint8))*200+25


for pre in (0xd3,0xa6):
    for ident in (0,1,255,256,32767,65535):
        samples=encoded(ident,pre)
        valid,got,p,_=unpack(samples)
        assert valid and got==ident and p==pre
        for bit in range(48):
            bad=samples.copy();bad[bit]=250-bad[bit]
            assert not unpack(bad)[0]
        ambiguous=samples.astype(float);ambiguous[9]=125
        assert not unpack(ambiguous)[0]

gray=np.zeros((480,640),dtype=np.uint8)+125
for pre,ys in ((0xd3,(64,448)),(0xa6,(464,))):
    for y in ys:
        gray[y:y+12,80:560]=np.repeat(encoded(1234,pre),10)
        c=dict(x=80,y=y+5,step=10,slope=0,pre=pre)
        assert decode_band(gray,c)==1234
        gray[y:y+4,80:560]=np.repeat(encoded(1235,pre),10)
        assert decode_band(gray,c) is None
        gray[y:y+12,80:560]=np.repeat(encoded(1234,pre),10)

cal=calibrate(gray)
assert set(cal)=={'camera_top','camera_bottom','scan'}
assert all(decode_band(gray,c)==1234 for c in cal.values())
print('PASS: 12 identity/checksum cases, every single-bit error, optical ambiguity, three-band acquisition')

curved=np.full((480,640),125,dtype=np.uint8)
for pre,y in ((0xd3,70),(0xd3,440),(0xa6,465)):
    for x in range(80,560):
        dx=x-80
        cy=int(round(y+0.0001*dx*(dx-480)))
        curved[cy-5:cy+6,x]=encoded(4321,pre)[dx//10]
    c=dict(x=80,y=y,step=10,slope=0,curvature=0.0001,pre=pre)
    assert decode_band(curved,c)==4321
assert not unpack(sample_line(curved,-10,70,10,0))[0]
cal=calibrate(curved,(0.0001,))
assert all(decode_band(curved,c)==4321 for c in cal.values())
print('PASS: curved optical coordinates and out-of-image rejection; no error-bit correction')
