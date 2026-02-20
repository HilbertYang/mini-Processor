import os


def open_file(arm):
    try:
        with open(arm, 'r') as f:                       
            contents = [[line.strip()] for line in f ] 
    except FileNotFoundError:
        raise FileNotFoundError(f"Error: File '{arm}' not found.")
    except Exception as e:
        raise (f"Error reading file '{arm}': {e}")
        
    ALLWRITE = []
    line = 0
    while line < len(contents):
        if contents[line][0] == '.LC0:':
            CM = contents[line][0]
            index = CM.find('@')
            if index != -1:
                CM = CM[:index].strip()
            ALLWRITE.append([CM])
            line += 1
            while contents[line][0].startswith('.word'):
                CM = contents[line][0]
                index = CM.find('@')
                if index != -1:
                    CM = CM[:index].strip()
                if not CM:
                    line += 1
                    continue  
                ALLWRITE.append([CM])
                line += 1
        elif contents[line][0] == 'main:':
            line += 1   
            while line < len(contents):
                if contents[line][0].startswith('.size'):
                    break
                else:
                    CM = contents[line][0]
                    index = CM.find('@')
                    if index != -1:
                        CM = CM[:index].strip()
                    if not CM:
                        line += 1
                        continue  
                    ALLWRITE.append([CM])
                    line += 1        
        else:
            line += 1
    
    return ALLWRITE

# arm = r'C:\Users\irryb\Desktop\533\L6\demo.s'
# ALLWRITE = open_file(arm)
# with open(r'C:\Users\irryb\Desktop\533\L6\pipeline.txt', 'w') as f:
#      for line in ALLWRITE:
#         f.write(f"{line[0]}\n")
