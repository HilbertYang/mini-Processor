import os
import re


# use line to define the line in arm file
# use PC to define the line in pipeline file, which is the same as the line in the complied instruction file


cmd_dist={ 
    ".word" : "dmem_write",

    "push" : 'imem_write',
    'add' : 'imem_write',
    'sub' : 'imem_write',
    'ldr' : 'imem_write',
    'mov' : 'imem_write',
    'cmp' : 'imem_write',
    'ldmia' : 'imem_write',
    'ldm' : 'imem_write',
    'str' : 'imem_write',
    'stmia' : 'imem_write',
    'stm' : 'imem_write',
    'lsl' : 'imem_write',


    "d_w" : "dmem_write",
    "d_r" : "dmem_read",


    "reset" : "pcreset",
    'run' : 'run 1',
    'step' : 'step',




    'lw' : 'imem_write',
    'sw' : 'imem_write',
    'nop' : 'imem_write'

}

ROT = "0000"

BI_MAP = {
    'ADD' : '0100',
    'SUB' : '0101',
    'MOV' : '1101',
    'LSL' : '0110',


    'con_process': '1110',


    'process_prefix' : '00',
    'S' : '0',
    'imm' : '1',
    'reg' : '0',


    'ls_prefix' : '0101',
    'ls_P' : '1',
    'ls_add' : '1',
    'ls_sub' : '0',
    'l_BNWL' : '001',
    'l_BWL' : '011',
    'S_BWL' : '000',
    'S_BNWL' : '010'

}

REGS_MAP = {
    'r0' : '0000',  #always 0
    'r1' : '0001',
    'r2' : '0010',
    'r3' : '0011',
    'r4' : '0100',
    'r5' : '0101',
    'r6' : '0110',
    'r7' : '0111',
    'r8' : '1000',
    'r9' : '1001',
    'r10' : '1010',
    'r11' : '1011',
    'sp' : '1100',
    'fp' : '1101',
    'lr' : '1110',
    'ip' : '1111'}

label_map = {

}# for all the potential jumps ,to store the label and line number to write PClabel_MAP
# .L0 : 2

pc_label_map = {

} 
# for all the potential jumps in our pipeline file, 
# .L0 : PC
# when there is a imm jump, we will look up this dist for the correct PC count
# if not found, we will write 'WAIT FOR EXECUTE' into that [] and store the line number and PC into NOT_FOUND_LABEL
# try at the end, if still not found, then we will raise error
# always make sure jump only take 1 PC line
NOT_FOUND_LABEL = []
# [[line, PC_line], [line, PC_line]]
# we will transfer line in arm file again and write it into the [[]_PC_line]

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

def build_instr(upcode, rn, rd, offset, line):
    # 4_con, 8_upcode, 4_rn, 4_rd, 12_offset
    bi_instr = f'{upcode}{rn}{rd}{offset}'
    if len(bi_instr) != 32:
        raise ValueError(f"Line {line}:  {bi_instr} Instruction length is not 32 bits")
    hex_instr = hex(int(bi_instr, 2))
    return hex_instr

def change_logic(ALLWRITE):
    global dmem_address
    global PC
    PC = 0
    for i in range(len(ALLWRITE)):
        if ALLWRITE[i][0].startswith('.'):
            if ALLWRITE[i][0].startswith('.word'):
                arm_2_pipeline(ALLWRITE[i][0], i)
            elif ALLWRITE[i][0].startswith('.LC'):
                label_map[ALLWRITE[i][0].split(':')[0]] = dmem_address
            elif ALLWRITE[i][0].startswith('.L'):
                label_map[ALLWRITE[i][0].split(':')[0]] = i+1
    

    for line in range(len(ALLWRITE)):
        if ALLWRITE[line][0].startswith('.'):
            line += 1
        else:
            arm_2_pipeline(ALLWRITE[line][0], line)
            line += 1
            # to be continued


def arm_2_pipeline(write_line, line):
    global dmem_address
    global PC
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
                print(f"line {line}is the end of the file, all readonly instructions have been processed.")
                return
            pipe_instr.append([f'{command} {addr} {high} {low}'])
    
    elif command == 'imem_write':
        if instr_decode[0] == 'push':
            regs = []
            match = re.search(r'\{([^}]+)\}', write_line)
            if match:
                regs.append(match.group(1).split(','))    # [['r0', 'r1', 'r2'']]
            else:
                raise ValueError(f"Invalid push instruction in line {line}: {write_line}")
            for reg in regs[0]:
                reg = REGS_MAP.get(reg.strip())
                if reg is None:
                    raise ValueError(f"Invalid register in line {line}: {reg}")
                #store to sp+4 then write back to sp
                prefix = '111001011010'
                offset = '1100000000000004'
                bi_instr = prefix + reg + offset
                hex_instr = hex(int(bi_instr, 2))

                pipe_instr.append([f'{command} {PC} {hex_instr}'])
                PC += 1
            return pipe_instr
                


        elif instr_decode[0] == 'add':
            op, data = write_line.split(maxsplit=1)
            data = [d.strip() for d in data.split(',')]
            try :
                rd = REGS_MAP.get(data[0])
                rn = REGS_MAP.get(data[1])
                if data[2].startswith('#'):
                    rt = hex_bi(data[2][1:], width=8)
                    r_ctrl = BI_MAP.get('imm')
                    offset = rt
                else:
                    r_ctrl = BI_MAP.get('reg')
                    rt = REGS_MAP.get(data[2])
                    offset = '0000'+rt
            except Exception:
                raise ValueError(f"Invalid add instruction in line {line}: {write_line}")
            
            cmd = BI_MAP.get('ADD') 
            upcode = f'{BI_MAP.get("con_process")}{BI_MAP.get("process_prefix")}{r_ctrl}{cmd}{BI_MAP.get("S")}'
            rot = ROT
            offset = rot + offset
            hex_instr = build_instr(upcode, rn, rd, offset, line)
            

        elif instr_decode[0] == 'sub':
            op, data = write_line.split(maxsplit=1)
            data = [d.strip() for d in data.split(',')]
            try :
                rd = REGS_MAP.get(data[0])
                rn = REGS_MAP.get(data[1])
                if data[2].startswith('#'):
                    rt = hex_bi(data[2][1:], width=8)
                    r_ctrl = BI_MAP.get('imm')
                    offset = rt
                else:
                    r_ctrl = BI_MAP.get('reg')
                    rt = REGS_MAP.get(data[2])
                    offset = '0000'+rt
            except Exception:
                raise ValueError(f"Invalid sub instruction in line {line}: {write_line}")
            cmd = BI_MAP.get('SUB')
            upcode = f'{BI_MAP.get("con_process")}{BI_MAP.get("process_prefix")}{r_ctrl}{cmd}{BI_MAP.get("S")}'
            rot = ROT
            offset = rot + offset
            hex_instr = build_instr(upcode, rn, rd, offset, line)
            
        
        elif instr_decode[0] == 'ldr':
            op, rd, data = write_line.split(maxsplit=2)
            rd = rd.strip()
            data = data.strip()
            match = re.search(r'\[([^\]]+)\]', data)
            if re.search(r'!\s*$', data):
                bwl = BI_MAP.get('l_BWL')
            else:
                bwl = BI_MAP.get('l_BNWL')
            dest = []
            if match:
                dest = match.group(1).split(',')  # get the destination register
                rn = REGS_MAP.get(dest[0].strip())
                if dest[1].startswith('#-'):
                    offset = hex_bi(dest[1][2:], width=8)
                    header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_sub') + bwl 
                elif dest[1].startswith('#'):
                    offset = hex_bi(dest[1][1:], width=8)
                    header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_add') + bwl 
                else:
                    raise ValueError(f"Invalid ldr instruction in line {line}: {write_line}")
            elif label_map.get(data) is not None:
                rn = REGS_MAP.get('r0') #use r0 as the base register
                offset = hex_bi(label_map.get(data), width=8)
                header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_add') + bwl
            else:
                raise ValueError(f"Invalid ldr instruction in line {line}: {write_line}")
            upcode = f'{BI_MAP.get("con_process")}{header}'
            rot = ROT
            offset = rot + offset
            hex_instr = build_instr(upcode, rn, rd, offset, line)
        
        elif instr_decode[0] == 'mov':
            op, data = write_line.split(maxsplit=1)
            data = [d.strip() for d in data.split(',')]
            try :
                rd = REGS_MAP.get(data[0])
                if data[1].startswith('#'):
                    rt = hex_bi(data[1][1:], width=8)
                    rn = '0000' # q: really connect rn to mov instruction?
                    r_ctrl = BI_MAP.get('imm')
                    offset = rt
                else:
                    r_ctrl = BI_MAP.get('reg')
                    rt = REGS_MAP.get(data[1])
                    offset = '0000'+rt
            except Exception:
                raise ValueError(f"Invalid sub instruction in line {line}: {write_line}")
            cmd = BI_MAP.get('MOV')
            # if data[0] == 'sp' or data[0] == 'fp' or data[0] == 'ip': #then we substract
            #     cmd = BI_MAP.get('ADD')
            #     rt = hex_bi(int(rt, 2) // 4, width=8)
            # else:
            #     cmd = BI_MAP.get('SUB')
            upcode = f'{BI_MAP.get("con_process")}{BI_MAP.get("process_prefix")}{r_ctrl}{cmd}{BI_MAP.get("S")}'
            rot = ROT
            offset = rot + offset
            hex_instr = build_instr(upcode, rn, rd, offset, line)
        
        elif instr_decode[0] == 'ldmia' or instr_decode[0] == 'ldm':
            op, rn, data = write_line.split(maxsplit=2)
            rn = rn.replace(',', '')
            if re.search('!', rn):
                rn = rn.replace('!', '')
                write_back = True
            else:
                write_back = False
            rn = rn.strip()
            regs = []
            match = re.search(r'\{([^}]+)\}', data)
            if match:
                regs.append(match.group(1).split(','))    # [['r0', 'r1', 'r2'']]
            else:
                raise ValueError(f"Invalid push instruction in line {line}: {write_line}")
            for reg in regs[0]:
                reg = reg.strip()
                if write_back:
                    w_l = f'ldr {reg}, [{rn}, #{0}]!'
                else:
                    w_l = f'ldr {reg}, [{rn}, #{0}]'
                pipe_instr.append(arm_2_pipeline(w_l, line))
            return pipe_instr
        
        elif instr_decode[0] == 'str':
            op, rd, data = write_line.split(maxsplit=2)
            rd = rd.strip()
            data = data.strip()
            match = re.search(r'\[([^\]]+)\]', data)
            if re.search(r'!\s*$', data):
                bwl = BI_MAP.get('S_BWL')
            else:
                bwl = BI_MAP.get('S_BNWL')
            dest = []
            if match:
                dest = match.group(1).split(',')  # get the destination register
                rn = REGS_MAP.get(dest[0].strip())
                if dest[1].startswith('#-'):
                    offset = hex_bi(dest[1][2:], width=8)
                    header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_sub') + bwl 
                elif dest[1].startswith('#'):
                    offset = hex_bi(dest[1][1:], width=8)
                    header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_add') + bwl 
                else:
                    raise ValueError(f"Invalid str instruction in line {line}: {write_line}")
            elif label_map.get(data) is not None:
                rn = REGS_MAP.get('r0') #use r0 as the base register
                offset = hex_bi(label_map.get(data), width=8)
                header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_add') + bwl
            else:
                raise ValueError(f"Invalid str instruction in line {line}: {write_line}")
            upcode = f'{BI_MAP.get("con_process")}{header}'
            rot = ROT
            offset = rot + offset
            hex_instr = build_instr(upcode, rn, rd, offset, line)
        
        elif instr_decode[0] == 'stmia' or instr_decode[0] == 'stm':
            op, rn, data = write_line.split(maxsplit=2)
            rn = rn.replace(',', '')
            if re.search('!', rn):
                rn = rn.replace('!', '')
                write_back = True
            else:
                write_back = False
            rn = rn.strip()
            regs = []
            match = re.search(r'\{([^}]+)\}', data)
            if match:
                regs.append(match.group(1).split(','))    # [['r0', 'r1', 'r2'']]
            else:
                raise ValueError(f"Invalid push instruction in line {line}: {write_line}")
            for reg in regs[0]:
                reg = reg.strip()
                if write_back:
                    w_l = f'str {reg}, [{rn}, #{0}]!'
                else:
                    w_l = f'str {reg}, [{rn}, #{0}]'
                pipe_instr.append(arm_2_pipeline(w_l, line))
            return pipe_instr
        
        elif instr_decode[0] == 'lsl':
            op, data = write_line.split(maxsplit=1)
            data = [d.strip() for d in data.split(',')]
            try :
                rd = REGS_MAP.get(data[0])
                rn = REGS_MAP.get(data[1])
                if data[2].startswith('#'):
                    rt = hex_bi(data[2][1:], width=8)
                    r_ctrl = BI_MAP.get('imm')
                    offset = rt
                else:
                    r_ctrl = BI_MAP.get('reg')
                    rt = REGS_MAP.get(data[2])
                    offset = '0000'+rt
            except Exception:
                raise ValueError(f"Invalid lsl instruction in line {line}: {write_line}")
            cmd = BI_MAP.get('LSL')
            upcode = f'{BI_MAP.get("con_process")}{BI_MAP.get("process_prefix")}{r_ctrl}{cmd}{BI_MAP.get("S")}'
            rot = ROT
            offset = rot + offset
            hex_instr = build_instr(upcode, rn, rd, offset, line)
        




        else:
            raise ValueError(f"Unknown command in line {line}: {instr_decode[0]}")
            

    pipe_instr.append([f'{command} {PC} {hex_instr}'])
    PC += 1
    return pipe_instr
            
            


