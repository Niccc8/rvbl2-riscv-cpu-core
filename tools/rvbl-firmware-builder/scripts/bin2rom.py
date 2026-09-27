# Confidencial - Propriedade do CPA Wernher von Braun

import sys

def main():
    if len(sys.argv) < 2:
        print("usage: python script.py <arquivo>")
        return

    try:
        with open(sys.argv[1], "rb") as file:
            address = 0x00400000
            
            while True:
                chunk = file.read(4)
                
                if len(chunk) < 4:
                    break
                
                binary = int.from_bytes(chunk, byteorder=sys.byteorder)
                
                print(f"32'h{address:08X}: r_Instruction = 32'h{binary:08X};")
                
                address += 4
                
    except FileNotFoundError:
        print("error: invalid file.")

if __name__ == "__main__":
    main()
