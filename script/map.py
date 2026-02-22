import os
import re

#if ! ,we should add first then offset == 0
#


# use line to define the line in arm file
# use PC to define the line in pipeline file, which is the same as the line in the complied instruction file


cmd_dist={ 
    ".word" : "dmem_write",

    "push" : 'imem_write',
    'pop' : 'imem_write',
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
    'bge' : 'imem_write',
    'ble' : 'imem_write',
    'b' : 'imem_write',
    'bx' : 'imem_write',


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
    'NOP' : '0xE0000000',


    'ADD' : '0100',
    'SUB' : '0010',
    'MOV' : '1101',
    'LSL' : '0110',
    'SLT' : '1011',


    'BEQ' : '00',
    'B' : '10',
    'BX' : '0001', #special
    
    'B_prefix' : '10',


    'con_process': '1110',


    'process_prefix' : '00',
    'S' : '0',
    'imm' : '1',
    'reg' : '0',


    'ls_prefix' : '01',
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

### we map r0 -> r11 , SLT sign bit -> r10,r9,  store imm SLT and SHIFT: r8
## test reg: r7


SLT_AB = '1010'  #this is for bge
SLT_BA = '1001'  #this is for ble

label_map = {

} #for all potential processed address in .LC
# .LC0 : 0x12345678

line_label_map = {

}
# for all the potential jumps ,to store the label and line number to write PClabel_MAP
#  2 : .L0
#  arm line2 has a label .L0

pc_label_map = {

} 
# .L0 : PC
# now we excute to .L0, and store the next line's PC

pp_label_map = {

}

# .L0 : PP 
# store the line number in our script to overwrite

branch_label_map = {

}
# for all the potential jumps in our pipeline file, 
# line : [branch_pc, rm]
# to store arm line number , instruction PC and right rm


# when there is a imm jump, we will look up this dist for the correct PC count
# if not found, we will write 'WAIT FOR EXECUTE' into that [] and store the line number and PC into NOT_FOUND_LABEL
# try at the end, if still not found, then we will raise error
# always make sure jump only take 1 PC line
NOT_FOUND_LABEL = []
# [[line, Pp_line], [line, Pp_line]] this is the beq line and b line that we have not found the label for, we will try to fill in the correct instruction at the end, if still not found, then we will raise error
# to store the arm line number and the script line number

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

def hex_bi(str, width=32, signed=False):
    value = de_hex(str)
    value = int(value, 16)
    if signed :
        mask = (1 << width) - 1
        value = value & mask
    return f'{value:0{width}b}'



def split32(str):
    value=de_hex(str)
    value = int(value, 16)
    high = (value >> 32) & 0xFFFFFFFF
    low = value & 0xFFFFFFFF
    return hex(high), hex(low)

def build_instr(upcode, rn, rd, offset, line):
    # 4_con, 8_upcode, 4_rn, 4_rd, 12_offset
    bi_instr = f'{upcode}{rn}{rd}{offset}'
    if len(bi_instr) != 32:
        raise ValueError(f"Line {line}:  {bi_instr} Instruction length is not 32 bits")
    hex_instr = hex(int(bi_instr, 2))
    return hex_instr

def change_logic(ALLWRITE, PC_start = 0, RMEM_START = 0, WORKPLACE_START = 0, NOP_NUM = 0):
    global dmem_address
    global PC 
    global pipe_line
    pipe_line = 0
    PC = 0
    PC = PC + PC_start
    dmem_address = dmem_address + RMEM_START
    reset_address = WORKPLACE_START

    output = []

    #reset all regs to 0
    for reg in REGS_MAP.keys():
        mov_instr = f'mov {reg}, #0'
        output.extend(arm_2_pipeline(mov_instr, -1, NOP_NUM = 0))
    
    output.extend(generic_nops(5)) # we can adjust the number of nops here to make sure the reset instruction takes 1 PC line, and we have enough time to write back to sp register before the next instruction

    for i in range(len(ALLWRITE)):
        if ALLWRITE[i][0].startswith('.'):
            if ALLWRITE[i][0].startswith('.word'):
                followinstr = arm_2_pipeline(ALLWRITE[i][0], i)
                if isinstance(followinstr, list):
                    output.extend(followinstr)
                else:
                    if line_label_map.get(i) :
                        label_map[line_label_map.get(i)] = followinstr
                    else:
                        line_label_map[i] = followinstr
            elif ALLWRITE[i][0].startswith('.LC'):
                label_map[ALLWRITE[i][0].split(':')[0]] = dmem_address
            elif ALLWRITE[i][0].startswith('.L'):
                if line_label_map.get(i+1) :
                    label_map[ALLWRITE[i][0].split(':')[0]] = line_label_map.get(i+1)
                else: 
                    line_label_map[i+1] = ALLWRITE[i][0].split(':')[0]

    
    

    for line in range(len(ALLWRITE)):
        if ALLWRITE[line][0].startswith('.'):
            pass
        else:
            label = line_label_map.get(line)
            if label is not None:
                PP_current = pipe_line
                PC_current = PC
                pc_label_map[label] = PC_current
                pp_label_map[label] = PP_current
            followinstr = arm_2_pipeline(ALLWRITE[line][0], line, NOP_NUM)
            output.extend(followinstr)
    
    print (f' total PC is {PC}, total pipe line is {pipe_line}')

    
    for i in range(len(NOT_FOUND_LABEL)):
        line, PP_line = NOT_FOUND_LABEL[i]   
        print(f'line {line} not found, instruction is {ALLWRITE[line][0]}')     
        followinstr = arm_2_pipeline(ALLWRITE[line][0], line, NOP_NUM)
        output[PP_line] = followinstr[0]
            # to be continued
    return output

def generic_nops(num):
    nops = []
    global PC
    global pipe_line
    for i in range(num):
        hex_instr = BI_MAP.get('NOP')
        nops.append([f'imem_write {PC} {hex_instr}'])
        PC += 1
        pipe_line += 1
        
    return nops

def arm_2_pipeline(write_line, line, NOP_NUM = 0):
    global dmem_address
    global PC
    global pipe_line
    write_line = write_line.replace('r0', 'r11') #replace r0 with r11 since r0 is always 0 in our design, we will use r10 to store the sign bit for slt instruction, and use r11 to store the value of r0
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
            dmem_address += 4
            data = instr_decode[1]
            try:
                high, low = split32(data)
            except Exception:
                print(f"line {line}is the end of the file, all readonly instructions have been processed.")
                taradd = label_map.get(instr_decode[1])
                return taradd
            pipe_instr.append([f'{command} {addr} {high} {low}'])
    
    elif command == 'imem_write':
        if instr_decode[0] == 'push':    #n+1 clk
            regs = []
            match = re.search(r'\{([^}]+)\}', write_line)
            if match:
                regs.append(match.group(1).split(','))    # [['r0', 'r1', 'r2'']]
            else:
                raise ValueError(f"Invalid push instruction in line {line}: {write_line}")
            for i in range(len(regs[0])):
                reg = REGS_MAP.get(regs[0][i].strip())
                if reg is None:
                    raise ValueError(f"Invalid register in line {line}: {reg}")
                #store to sp-4 then write back to sp register
                prefix = '111001010010'
                addr = hex_bi(f'{4*(i+1)}', width=8) #4, 8, 12...
                offset = '11000000' + addr
                # offset = '1100000000000100' 
                bi_instr = prefix + reg + offset
                hex_instr = hex(int(bi_instr, 2))

                pipe_instr.append([f'{command} {PC} {hex_instr}'])
                PC += 1
                pipe_line += 1
                pipe_instr.extend(generic_nops(NOP_NUM)) 
                
            endaddr = 4*len(regs[0]) 
            sub_instr = f'sub sp, sp, #{endaddr}'
            pipe_instr.extend(arm_2_pipeline(sub_instr, line, NOP_NUM))  #ADD PC in inner instrution
            return pipe_instr
        
        elif instr_decode[0] == 'pop':
            regs = []
            match = re.search(r'\{([^}]+)\}', write_line)
            if match:
                regs.append(match.group(1).split(','))    # [['r0', 'r1', 'r2'']]
            else:
                raise ValueError(f"Invalid pop instruction in line {line}: {write_line}")
            for i in range(len(regs[0])):
                reg = REGS_MAP.get(regs[0][i].strip())
                if reg is None:
                    raise ValueError(f"Invalid register in line {line}: {reg}")
                #load from sp then write sp+4 back to sp register
                addr = hex_bi(f'{4*i}', width=8) #0, 4, 8...
                offset = '11000000' + addr
                prefix = '111001011010'
                # offset = '1100000000000100' #4
                bi_instr = prefix + reg + offset
                hex_instr = hex(int(bi_instr, 2))

                pipe_instr.append([f'{command} {PC} {hex_instr}'])
                PC += 1
                pipe_line += 1
                pipe_instr.extend(generic_nops(NOP_NUM)) 
                
            endaddr = 4*len(regs[0]) 
            add_instr = f'add sp, sp, #{endaddr}'
            pipe_instr.extend(arm_2_pipeline(add_instr, line, NOP_NUM))  #ADD PC in inner instrution
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
            rd = rd.replace(',', '').strip()
            rd = REGS_MAP.get(rd)
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
                dest[1] = dest[1].strip()
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
                offset = hex_bi(f'{label_map.get(data)}', width=8)
                header = BI_MAP.get('ls_prefix') +BI_MAP.get('imm') + BI_MAP.get('ls_P') + BI_MAP.get('ls_add') + bwl
            else:
                raise ValueError(f"Invalid ldr instruction in line {line}: {write_line}")
            upcode = f'{BI_MAP.get("con_process")}{header}'
            rot = ROT
            offset = rot + offset
            # add a WB
            if re.search(r'!\s*$', data):
                reg_name = dest[0].strip() # Get the raw string 
                imm_val = dest[1].strip()  # Get the raw offset 
    
                if imm_val.startswith('#-'):
                    w_l = f'sub {reg_name}, {reg_name}, #{imm_val[2:]}'
                else:
                    w_l = f'add {reg_name}, {reg_name}, {imm_val}'
                
                pipe_instr.extend(arm_2_pipeline(w_l, line, NOP_NUM)) 
                offset = '0000' + '00000000' # we have write back to the base register, so the offset is 0 now
            
            
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
                    rt = REGS_MAP.get(data[0])
                    offset = '0000' + rt
                    rn = '0000' # q: really connect rn to mov instruction?
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
            for i in range(len(regs[0])):
                reg = regs[0][i]
                reg = reg.strip()
                offset = i*4
                w_l = f'ldr {reg}, [{rn}, #{offset}]'
                pipe_instr.extend(arm_2_pipeline(w_l, line, NOP_NUM))
            if write_back:
                w_l = f'add {rn}, {rn}, #{len(regs[0])*4}'
                pipe_instr.extend(arm_2_pipeline(w_l, line, NOP_NUM))  #ADD PC in inner instrution
            return pipe_instr
        
        elif instr_decode[0] == 'str':
            op, rd, data = write_line.split(maxsplit=2)
            NOP_NUM = 0
            rd = rd.replace(',', '').strip()
            rd = REGS_MAP.get(rd)
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
                dest[1] = dest[1].strip()
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

            if re.search(r'!\s*$', data):
                reg_name = dest[0].strip() # Get the raw string 
                imm_val = dest[1].strip()  # Get the raw offset 
    
                if imm_val.startswith('#-'):
                    w_l = f'sub {reg_name}, {reg_name}, #{imm_val[2:]}'
                else:
                    w_l = f'add {reg_name}, {reg_name}, {imm_val}'
                
                pipe_instr.extend(arm_2_pipeline(w_l, line, NOP_NUM)) 
                offset = '0000' + '00000000' # we have write back to the base register, so the offset is 0 now

            
            hex_instr = build_instr(upcode, rn, rd, offset, line)
        
        elif instr_decode[0] == 'stmia' or instr_decode[0] == 'stm':
            op, rn, data = write_line.split(maxsplit=2)
            rn = rn.replace(',', '')
            NOP_NUM = 0
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
            for i in range(len(regs[0])):
                reg = regs[0][i]
                reg = reg.strip()
                offset = i*4
                w_l = f'str {reg}, [{rn}, #{offset}]'
                pipe_instr.extend(arm_2_pipeline(w_l, line, NOP_NUM))
            if write_back:
                w_l = f'add {rn}, {rn}, #{len(regs[0])*4}'
                pipe_instr.extend(arm_2_pipeline(w_l, line, NOP_NUM))  #ADD PC in inner instrution
            return pipe_instr
        
        elif instr_decode[0] == 'lsl':
            op, data = write_line.split(maxsplit=1)
            data = [d.strip() for d in data.split(',')]
            try :
                rd = REGS_MAP.get(data[0])
                rn = REGS_MAP.get(data[1])
                # if data[2].startswith('#'):
                #     rt = hex_bi(data[2][1:], width=8)
                #     r_ctrl = BI_MAP.get('imm')
                #     offset = rt
                # else:
                #     r_ctrl = BI_MAP.get('reg')
                #     rt = REGS_MAP.get(data[2])
                #     offset = '0000'+rt
                if data[2].startswith('#'): #MOV the imm to r8 then use r8
                    mov_instr = f'mov r8, {data[2]}'
                    pipe_instr.extend(arm_2_pipeline(mov_instr, line, NOP_NUM))
                    r_ctrl = BI_MAP.get('reg')
                    offset = '0000' + REGS_MAP.get('r8')
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
        
        elif instr_decode[0] == 'cmp': #we use SLT
            op, data = write_line.split(maxsplit=1)
            data = [d.strip() for d in data.split(',')]
            try :
                r1 = REGS_MAP.get(data[0])
                if data[1].startswith('#'):
                    mov_instr = f'mov r8, {data[1]}'
                    pipe_instr.extend(arm_2_pipeline(mov_instr, line, NOP_NUM))
                    r2 = REGS_MAP.get('r8')
                    # r2 = hex_bi(data[1][1:], width=8)
                    # r_ctrl = BI_MAP.get('imm')
                    # offset = r2
                else:
                    r2 = REGS_MAP.get(data[1])
                # if data[2].startswith('#'):
                #     rt = hex_bi(data[2][1:], width=8)
                #     r_ctrl = BI_MAP.get('imm')
                #     offset = rt
                # else:
                #     r_ctrl = BI_MAP.get('reg')
                #     rt = REGS_MAP.get(data[2])
                #     offset = '0000'+rt
                r_ctrl = BI_MAP.get('reg')
                rot = ROT
            except Exception:
                raise ValueError(f"Invalid cmp instruction in line {line}: {write_line}")
            cmd = BI_MAP.get('con_process') + BI_MAP.get('process_prefix') + r_ctrl + BI_MAP.get('S')+ BI_MAP.get('SLT')
            for i in range(2):
                if i == 0:
                    rn = r1
                    rm = r2
                    rd = SLT_AB  #for bge 
                    offset = ROT + '0000' +rm                   
                    hex_instr = build_instr(cmd, rn, rd, offset, line)
                else:
                    rn = r2
                    rm = r1
                    rd = SLT_BA #for ble
                    offset = ROT + '0000' +rm
                    hex_instr = build_instr(cmd, rn, rd, offset, line)
                pipe_instr.append([f'{command} {PC} {hex_instr}'])
                PC += 1
                pipe_line += 1
                pipe_instr.extend(generic_nops(NOP_NUM)) # we can adjust the number of nops here to make sure the cmp instruction takes 2 PC lines, and we have enough time to write the sign bit to r10 before the next instruction
            return pipe_instr
        
        elif instr_decode[0] == 'bge' or instr_decode[0] == 'ble':
            jump_label = pc_label_map.get(instr_decode[1]) #this  is  target PC
            if instr_decode[0] == 'bge':
                rm = SLT_AB
            else:
                rm = SLT_BA
            rn = REGS_MAP.get('r0') #we don't care about the value in r0 since we only care about the sign bit for slt instruction, and we have stored the sign bit in r10
            if branch_label_map.get(line) is not None:
                    pc_current = branch_label_map.get(line)[0]
                    rm = branch_label_map.get(line)[1]
            else:
                pc_current = PC
            if jump_label is not None:                
                off16 = jump_label - pc_current - 2
                offset = hex_bi(f'{off16}', width=16, signed=True)
                header = BI_MAP.get('B_prefix') + BI_MAP.get('BEQ')
                cmd = f'{BI_MAP.get("con_process")}{header}'
                hex_instr = build_instr(cmd, rn, rm, offset, line)
                pipe_instr.append([f'{command} {pc_current} {hex_instr}'])
                if pc_current != PC:
                    pass
                else:
                    PC += 1
                    pipe_line += 1
                    pipe_instr.extend(generic_nops(NOP_NUM))
            else :
                pp_current = pipe_line
                #store the line and PC into NOT_FOUND_LABEL and write 'WAIT FOR EXECUTE' into that line in pipe_instr, we will try to fill in the correct instruction at the end
                NOT_FOUND_LABEL.append([line, pp_current])
                branch_label_map[line] = [PC, rm]
                hex_instr = 'WAIT FOR EXECUTE'
                pipe_instr.append([f'{command} {pc_current} {hex_instr}'])
                PC += 1
                pipe_line += 1
                pipe_instr.extend(generic_nops(NOP_NUM))
            
            
             # we can adjust the number of nops here to make sure the branch instruction takes 1 PC line, and we have enough time to write back to sp register before the next instruction
            return pipe_instr
        
        elif instr_decode[0] == 'b':
            jump_label = pc_label_map.get(instr_decode[1]) #this  is  target PC
            if branch_label_map.get(line) is not None:
                    pc_current = branch_label_map.get(line)[0]
            else:
                pc_current = PC
            if jump_label is not None:               
                off16 = jump_label - pc_current - 2
                offset = hex_bi(f'{off16}', width=9, signed=True)
                offset = '0000' + '000' +offset
                rn = '0000'
                rd = '0000'
                header = BI_MAP.get('B_prefix') + BI_MAP.get('B')
                cmd = f'{BI_MAP.get("con_process")}{header}'
                hex_instr = build_instr(cmd, rn, rd, offset, line)
                pipe_instr.append([f'{command} {pc_current} {hex_instr}'])
                if pc_current != PC:
                    pass
                else:
                    PC += 1
                    pipe_line += 1
                    pipe_instr.extend(generic_nops(NOP_NUM))
            else :
                #store the line and PC into NOT_FOUND_LABEL and write 'WAIT FOR EXECUTE' into that line in pipe_instr, we will try to fill in the correct instruction at the end
                pp_current = pipe_line
                NOT_FOUND_LABEL.append([line, pp_current])
                branch_label_map[line] = [PC, '0000'] #we will fill in the correct PC later, but we know the rm field is 0000 for unconditional jump
                hex_instr = 'WAIT FOR EXECUTE'
                pipe_instr.append([f'{command} {pc_current} {hex_instr}'])
                PC += 1
                pipe_line += 1
                pipe_instr.extend(generic_nops(NOP_NUM))           
            
             # we can adjust the number of nops here to make sure the unconditional jump instruction takes 1 PC line, and we have enough time to write back to sp register before the next instruction
            return pipe_instr
        
        elif instr_decode[0] == 'bx':  #special
            rm = REGS_MAP.get(instr_decode[1])
            cmd = '11100001'
            rn = '0010'
            rd = '1111'
            offset = '11111111' + '0001' + rm
            hex_instr = build_instr(cmd, rn, rd, offset, line)
        

            



            
            
            


        




        else:
            raise ValueError(f"Unknown command in line {line}: {instr_decode[0]}")
            

        pipe_instr.append([f'{command} {PC} {hex_instr}'])
        PC += 1
    pipe_line += 1
    pipe_instr.extend(generic_nops(NOP_NUM))
    return pipe_instr

def main():
    with open('C:\\Users\\irryb\\Desktop\\533\\L6\\line.txt', 'r') as f:
        all_lines = [[line.strip()] for line in f ]
    output = change_logic(all_lines, PC_start=0, RMEM_START=0, WORKPLACE_START=0, NOP_NUM=4)
    with open('C:\\Users\\irryb\\Desktop\\533\\L6\\pp_output.txt', 'w') as f:
        for line in output:
            f.write(line[0] + '\n')
            
if __name__ == "__main__":
    main()


