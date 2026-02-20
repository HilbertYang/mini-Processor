import os
import re

cmd_dist={ 
    ".word" : "dmem_write",

    "d_w" : "dmem_write",
    "d_r" : "dmem_read",


    "reset" : "pcreset",
    'run' : 'run 1',
    'step' : 'step',




    'lw' : 'imem_write',
    'sw' : 'imem_write',
    'nop' : 'imem_write'

}

dmem_address = 0

def de_hex(str):
    if str.startswith('0x'):
        return hex(int(str, 16))
    elif str.startswith('$'):
        str = str[1:]
        return hex(int(str))
    else:
        return hex(int(str))

def hex_bi(str, width=32):
    value = de_hex(str)
    value = int(value, 16)
    return f'{value:0{width}b}'

def split(str):
    value=de_hex(str)
    high = (value >> 32) & 0xFFFFFFFF
    low = value & 0xFFFFFFFF
    return high, low


def arm_2_pipeline(write_line, line, PC):
    global dmem_address
    instr_decode = write_line.split()
    pipe_instr = []
    command = cmd_dist.get(instr_decode[0])
    if command is None:
        raise ValueError(f"Unknown command: {instr_decode[0]}")
    if command == 'dmem_write':
        if instr_decode[0] == '.word':
            if len(instr_decode) < 2:
                raise ValueError(f"Invalid instruction in line {line}: {' '.join(instr_decode)}")
            addr = dmem_address
            dmem_address += 1
            data = instr_decode[1]
            try:
                high, low = split(data)
            except Exception:
                print(f"line {line}is the end of the file, all complied instructions have been processed.")
            pipe_instr.append([f'{command} {addr} {high} {low}'])
    
    elif command == 'imem_write':
        if instr_decode[0] == 'push':
            regs = []
            match = re.search(r'\{([^}]+)\}', write_line)
            if match:
                regs.append(match.group(1).split(','))    # ['r0', 'r1', 'r2'']
            else:
                raise ValueError(f"Invalid push instruction in line {line}: {write_line}")
            for reg in regs[0]:
                reg = reg.strip()
                if reg.startswith('r'):
                    reg_num = int(reg[1:])
                    if 0 <= reg_num <= 15:
                        pipe_instr.append([f'{command} {PC} {reg_num}'])
                    else:
                        raise ValueError(f"Invalid register number in line {line}: {reg}")
                else:
                    raise ValueError(f"Invalid register format in line {line}: {reg}")

    

    return pipe_instr
            
            


