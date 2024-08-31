import matplotlib.pyplot as mpl
import matplotlib.collections as mc
import os.path
import math
import zlib
import struct

from nsim import *

OUTTE_MODE = True #Only set to False when manually running the script. Changes what the output of the tool is.
COMPRESSED_INPUTS = True #Only set to False when manually running the script and using regular uncompressed input files.
DEBUG_OUTPUT = True #Print debug logs to the terminal in manual mode.
TABLE_OUTPUT = True #Use table format for the debug logs, rather than dumping them raw

#Required names for files. Only change values if running manually.
RAW_INPUTS_0 = "inputs_0"
RAW_INPUTS_1 = "inputs_1"
RAW_INPUTS_2 = "inputs_2"
RAW_INPUTS_3 = "inputs_3"
RAW_MAP_DATA = "map_data"
RAW_INPUTS_EPISODE = "inputs_episode"
RAW_MAP_DATA_0 = "map_data_0"
RAW_MAP_DATA_1 = "map_data_1"
RAW_MAP_DATA_2 = "map_data_2"
RAW_MAP_DATA_3 = "map_data_3"
RAW_MAP_DATA_4 = "map_data_4"
OUTPUT_TRACE = "output.bin"
OUTPUT_SPLITS = "output.txt"

MAP_IMG = None #This one is only needed for manual execution

#Import inputs.
inputs_list = []
if os.path.isfile(RAW_INPUTS_EPISODE):
    tool_mode = "splits"
    with open(RAW_INPUTS_EPISODE, "rb") as f:
        inputs_episode = zlib.decompress(f.read()).split(b"&")
        for inputs_level in inputs_episode:
            inputs_list.append([int(b) for b in inputs_level])
else:
    tool_mode = "trace"
if os.path.isfile(RAW_INPUTS_0):
    with open(RAW_INPUTS_0, "rb") as f:
        if COMPRESSED_INPUTS:
            inputs_list.append([int(b) for b in zlib.decompress(f.read())])
        else:
            inputs_list.append([int(b) for b in f.read()][215:])
if os.path.isfile(RAW_INPUTS_1):
    with open(RAW_INPUTS_1, "rb") as f:
        if COMPRESSED_INPUTS:
            inputs_list.append([int(b) for b in zlib.decompress(f.read())])
        else:
            inputs_list.append([int(b) for b in f.read()][215:])
if os.path.isfile(RAW_INPUTS_2):
    with open(RAW_INPUTS_2, "rb") as f:
        if COMPRESSED_INPUTS:
            inputs_list.append([int(b) for b in zlib.decompress(f.read())])
        else:
            inputs_list.append([int(b) for b in f.read()][215:])
if os.path.isfile(RAW_INPUTS_3):
    with open(RAW_INPUTS_3, "rb") as f:
        if COMPRESSED_INPUTS:
            inputs_list.append([int(b) for b in zlib.decompress(f.read())])
        else:
            inputs_list.append([int(b) for b in f.read()][215:])

#import map data
mdata_list = []
if tool_mode == "trace":
    with open(RAW_MAP_DATA, "rb") as f:
        mdata = [int(b) for b in f.read()]
    for _ in range(len(inputs_list)):
        mdata_list.append(mdata)
elif tool_mode == "splits":
    with open(RAW_MAP_DATA_0, "rb") as f:
        mdata_list.append([int(b) for b in f.read()])
    with open(RAW_MAP_DATA_1, "rb") as f:
        mdata_list.append([int(b) for b in f.read()])
    with open(RAW_MAP_DATA_2, "rb") as f:
        mdata_list.append([int(b) for b in f.read()])
    with open(RAW_MAP_DATA_3, "rb") as f:
        mdata_list.append([int(b) for b in f.read()])
    with open(RAW_MAP_DATA_4, "rb") as f:
        mdata_list.append([int(b) for b in f.read()])

#Logs for debugging, traces and splits
poslog       = []
speedlog     = []
goldlog      = []
frameslog    = []
validlog     = []
collisionlog = []
entitylog    = []

#This dictionary converts raw input data into the horizontal and jump components.
HOR_INPUTS_DIC = {0:0, 1:0, 2:1, 3:1, 4:-1, 5:-1, 6:-1, 7:-1}
JUMP_INPUTS_DIC = {0:0, 1:1, 2:0, 3:1, 4:0, 5:1, 6:0, 7:1}

#Repeat this loop for each individual replay
for i in range(len(inputs_list)):
    valid = False

    #Extract inputs and map data from the list
    inputs = inputs_list[i]
    mdata = mdata_list[i]

    #Convert inputs in a more useful format.
    hor_inputs = [HOR_INPUTS_DIC[inp] for inp in inputs]
    jump_inputs = [JUMP_INPUTS_DIC[inp] for inp in inputs]
    inp_len = len(inputs)

    #Initiate simulator and load the level
    sim = Simulator()
    sim.load(mdata)

    #Execute the main physics function once per frame
    while sim.frame < inp_len:
        hor_input = hor_inputs[sim.frame]
        jump_input = jump_inputs[sim.frame]
        sim.tick(hor_input, jump_input)
        if sim.ninja.state == 6:
            break
        if sim.ninja.state == 8:
            if sim.frame == inp_len:
                valid = True
            break

    #Append to the logs for each replay.
    poslog.append(sim.ninja.poslog)
    speedlog.append(sim.ninja.speedlog)
    frameslog.append(inp_len)
    validlog.append(valid)
    collisionlog.append(sim.collisionlog)

    #Entity position logs, including the ninja, for exporting.
    entities = [(0, 0, [log[1:] for log in sim.ninja.poslog])]
    entities += [(e.type, e.index, e.poslog) for e in sim.entity_list if e.log_positions]
    entitylog.append(entities)

    #Calculate the amount of gold collected for each replay.
    gold_amount = struct.unpack('<H', struct.pack('<2B', *mdata[1154:1156]))[0]
    gold_collected = sum(e.type == 2 and e.collected for e in sim.entity_list)
    goldlog.append((gold_collected, gold_amount))

#Print info useful for debug if in manual mode
if not OUTTE_MODE and DEBUG_OUTPUT:
    if TABLE_OUTPUT:
        sep = f"+------+{(('-' * 44) + '+') * len(inputs_list)}"
        sep_short = f"       {sep[7:]}"
        print(sep_short)
        print(f"       |{'|'.join(map(lambda valid: f'{str(valid):^44}', validlog))}|")
        print(sep_short)
        print(f"""       |{f" {'X':^11} {'Y':^10} {'VX':^9} {'VY':^9} |" * 4}""")
        print(sep)
        frames = max(map(len, inputs_list))
        for f in range(frames):
            line = f"| {f:>4} |"
            for i in range(len(inputs_list)):
                if len(poslog[i]) > f:
                    line += " %11.6f %10.6f %9.6f %9.6f |" % (poslog[i][f][1:] + speedlog[i][f][1:])
                else:
                    line += " " * 44 + "|"
            print(line)
            if (f + 1) % 10 == 0: print(sep)
        if frames % 10 != 0: print(sep)
    else:
        for i in range(len(inputs_list)):
            print(speedlog[i])
            print(poslog[i])
            print(validlog[i])

#Plot the route. Only ran in manual mode.
if tool_mode == "trace" and OUTTE_MODE == False:
    colors = ["#000000", "#EADA56", "#4D31AA", "#910A46"]
    for i in range(len(inputs_list) - 1, -1, -1):
        mpl.plot(*list(zip(*poslog[i]))[1:], colors[i])
    mpl.axis([0, 1056, 600, 0])
    mpl.axis("off")
    ax = mpl.gca()
    ax.set_aspect("equal", adjustable="box")
    if MAP_IMG:
        img = mpl.imread(MAP_IMG)
        ax.imshow(img, extent=[0, 1056, 600, 0])
    lines = []
    for cell in sim.segment_dic.values():
        for segment in cell:
            if segment.type == "linear":
                lines.append([(segment.x1, segment.y1), (segment.x2, segment.y2)])
            elif segment.type == "circular":
                angle = math.atan2(segment.hor, segment.ver) + (math.pi if segment.hor != segment.ver else 0)
                a1 = angle - math.pi/4
                a2 = angle + math.pi/4
                dist = a2 - a1
                quality = 8
                inc = dist / quality
                x1 = segment.xpos + segment.radius*math.cos(a1)
                y1 = segment.ypos + segment.radius*math.sin(a1)
                for i in range(1, quality+1):
                    a1 += inc
                    x2 = segment.xpos + segment.radius*math.cos(a1)
                    y2 = segment.ypos + segment.radius*math.sin(a1)
                    lines.append([(x1, y1), (x2, y2)])
                    x1, y1 = x2, y2
    lc = mc.LineCollection(lines)
    ax.add_collection(lc)
    mpl.show()
            
# Export simulation result for outte
if tool_mode == "trace" and OUTTE_MODE == True:
    with open(OUTPUT_TRACE, "wb") as f:
        # Write run count, and then valid log (1 byte per run)
        n = len(inputs_list)
        f.write(struct.pack('B', n))
        f.write(struct.pack(f'{n}B', *validlog))
        for i in range(n):
            # Entity section: Positions of logged entities, including ninja
            entities = len(entitylog[i])
            f.write(struct.pack('<H', entities))
            for j in range(entities):
                entity = entitylog[i][j]
                frames = len(entity[2])
                f.write(struct.pack('<BHH', *(entity[:2] + (frames,))))
                for frame in range(frames):
                    f.write(struct.pack('<2d', *entity[2][frame]))
            # Collision section
            collisions = len(collisionlog[i])
            f.write(struct.pack('<H', collisions))
            for col in range(collisions):
                f.write(struct.pack('<HBHB', *collisionlog[i][col]))
    print("%.3f" % ((90 * 60 - frameslog[0] + 1 + goldlog[0][0] * 120) / 60))

#Print episode splits and other info to the console. Only ran in manual mode and splits mode.
if tool_mode == "splits" and OUTTE_MODE == False:
    print("SI-A-00 0th replay analysis:")
    split = 90*60
    for i in range(5):
        split = split - frameslog[i] + 1 + goldlog[i][0]*120
        split_score = round(split/60, 3)
        print(f"{i}:-- Is replay valid?: {validlog[i]} | Gold collected: {goldlog[i][0]}/{goldlog[i][1]} | Replay length: {frameslog[i]} frames | Split score: {split_score:.3f}")

#For each level of the episode, write to file whether the replay is valid, then write the score split. Only ran in outte mode and in splits mode.
if tool_mode == "splits" and OUTTE_MODE == True:
    split = 90*60
    with open(OUTPUT_SPLITS, "w") as f:
        for i in range(5):
            print(validlog[i], file=f)
            split = split - frameslog[i] + 1 + goldlog[i][0]*120
            print(split, file=f)