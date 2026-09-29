def expand_fields(payload: bytes):
    out=[]
    specs=((1,"u8",False),(1,"s8",True),(2,"u16",False),(2,"s16",True),(3,"u24",False),(4,"u32",False),(4,"s32",True))
    for i,b in enumerate(payload):
        for bit in range(8): out.append((i,f"bit{bit}",(b>>bit)&1))
        for n,name,signed in specs:
            if i+n>len(payload): continue
            chunk=payload[i:i+n]
            if n==1: out.append((i,name,int.from_bytes(chunk,"big",signed=signed)))
            elif n==3: out.append((i,name,int.from_bytes(chunk,"big",signed=False)))
            else:
                for endian,suffix in (("big","be"),("little","le")):
                    out.append((i,name+suffix,int.from_bytes(chunk,endian,signed=signed)))
    return out
