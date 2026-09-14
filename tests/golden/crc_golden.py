"""
Independent Python reference model for the Xicrc CRC-16 engine.
Implements the exact bit-serial algorithm from spec §13.2 (CRC-16-CCITT-FALSE:
poly=0x1021, MSB-first, no reflection, no final XOR), completely independently
of the RTL's unrolled-for-loop implementation, so this is a genuine
cross-check rather than the same logic transcribed twice.
"""
POLY = 0x1021

def crc16_update(seed, data, nbits):
    crc = seed & 0xFFFF
    for i in range(nbits):
        bit_in = (data >> (nbits - 1 - i)) & 1
        fb = ((crc >> 15) & 1) ^ bit_in
        crc = ((crc << 1) & 0xFFFF)
        if fb:
            crc ^= POLY
    return crc & 0xFFFF

def crcb(seed, data8):  return crc16_update(seed, data8 & 0xFF, 8)
def crch(seed, data16): return crc16_update(seed, data16 & 0xFFFF, 16)
def crcw(seed, data32): return crc16_update(seed, data32 & 0xFFFFFFFF, 32)

# --- Sanity-check the golden model itself before trusting it as an oracle ---
# Standard CRC-16/CCITT-FALSE check value for ASCII "123456789", chained one
# byte (CRCB) at a time starting from seed 0xFFFF.
def self_check():
    seed = 0xFFFF
    for ch in b"123456789":
        seed = crcb(seed, ch)
    return seed

if __name__ == "__main__":
    val = self_check()
    print(f"Self-check CRC-16/CCITT-FALSE('123456789') = 0x{val:04X} (expect 0x29B1)")
    assert val == 0x29B1, "Golden model does not reproduce the standard CRC-16/CCITT-FALSE check value!"

    import random, os
    random.seed(42)
    vectors = []  # (funct3, rs1_seed, rs2_data, expected)

    # Directed vectors
    directed = [
        (0, 0xFFFF, 0x00000000),
        (0, 0xFFFF, 0x000000FF),
        (1, 0xFFFF, 0x00000000),
        (1, 0xFFFF, 0x0000FFFF),
        (2, 0xFFFF, 0x00000000),
        (2, 0xFFFF, 0xFFFFFFFF),
        (2, 0xFFFF, 0x39383736),  # "6789" little-endian-ish word, arbitrary
        (1, 0x0000, 0x0000),
        (1, 0x1234, 0xABCD),
    ]
    for f3, seed, data in directed:
        if f3 == 0: exp = crcb(seed, data)
        elif f3 == 1: exp = crch(seed, data)
        else: exp = crcw(seed, data)
        vectors.append((f3, seed, data, exp))

    # Chained full check-value test: 9 sequential CRCB calls over "123456789"
    seed = 0xFFFF
    chain_steps = []
    for ch in b"123456789":
        nxt = crcb(seed, ch)
        chain_steps.append((0, seed, ch, nxt))
        seed = nxt
    assert seed == 0x29B1

    # Randomized vectors, all 3 widths
    for _ in range(300):
        seed = random.randint(0, 0xFFFF)
        f3 = random.choice([0,1,2])
        if f3 == 0:
            data = random.randint(0, 0xFF); exp = crcb(seed, data)
        elif f3 == 1:
            data = random.randint(0, 0xFFFF); exp = crch(seed, data)
        else:
            data = random.randint(0, 0xFFFFFFFF); exp = crcw(seed, data)
        vectors.append((f3, seed, data, exp))

    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'crc_vectors.txt'), 'w') as f:
        for f3, seed, data, exp in vectors:
            f.write(f"{f3} {seed:08x} {data:08x} {exp:08x}\n")
        for f3, seed, data, exp in chain_steps:
            f.write(f"{f3} {seed:08x} {data:08x} {exp:08x}\n")

    print(f"Wrote {len(vectors)+len(chain_steps)} CRC vectors (incl. chained check-value sequence)")
