import random
import unittest
from wire import *

class WireTests(unittest.TestCase):
    def test_every_header_split_and_coalesced_packets(self):
        a, b = packet(b'abc', 0, 0, True), packet(b'defghi', 1, 33333)
        for split in range(len(a+b)+1):
            p=PacketParser()
            got=p.feed((a+b)[:split])+p.feed((a+b)[split:])
            self.assertEqual(got,[(0,0,1,b'abc'),(1,33333,0,b'defghi')])

    def test_reject_oversize_and_bad_magic(self):
        for h in [HEADER.pack(b'BAD!',1,1,0,1,0,0),HEADER.pack(MAGIC,1,1,0,MAX_PAYLOAD+1,0,0)]:
            with self.assertRaises(ValueError): PacketParser().feed(h)

    def test_annexb_all_chunk_boundaries_and_eof(self):
        raw=b'\x00\x00\x00\x01\x09\xf0\x00\x00\x01\x67abc\x00\x00\x00\x01\x65xyz'
        for split in range(len(raw)+1):
            p=AnnexBParser()
            got=p.feed(raw[:split])+p.feed(raw[split:])+p.feed(b'',True)
            self.assertEqual(got,[b'\x09\xf0',b'\x67abc',b'\x65xyz'])

    def test_aud_groups_multislice_picture(self):
        a=AccessUnits(); got=[]
        for n in [b'\x09x',b'\x67s',b'\x68p',b'\x65a',b'\x65b',b'\x09x',b'\x41c']:
            got+=a.push(n)
        got+=a.flush()
        self.assertEqual(len(got),2)
        self.assertTrue(got[0][1]); self.assertFalse(got[1][1])
        self.assertIn(b'\x65a',got[0][0]); self.assertIn(b'\x65b',got[0][0])

    def test_random_byte_fragmentation(self):
        rnd=random.Random(27)
        expected=[(i,i*33333,i%30==0,bytes([i%256])*rnd.randint(1,400)) for i in range(120)]
        raw=b''.join(packet(data,i,pts,key) for i,pts,key,data in expected)
        p=PacketParser(); got=[]
        while raw:
            n=rnd.randint(1,107); got+=p.feed(raw[:n]); raw=raw[n:]
        self.assertEqual(got,expected)

if __name__ == '__main__': unittest.main()
