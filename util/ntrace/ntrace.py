import os.path
import zlib
import struct

from nsim import *


#Required names for files.
RAW_INPUTS = ["inputs_0", "inputs_1", "inputs_2", "inputs_3"]
RAW_MAP_DATA = "map_data"
RAW_INPUTS_EPISODE = "inputs_episode"
RAW_MAP_DATA_EPISODE = ["map_data_0", "map_data_1", "map_data_2", "map_data_3", "map_data_4"]
OUTPUT_TRACE = "output.bin"
OUTPUT_SPLITS = "output.txt"

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
    for rinputs in RAW_INPUTS:
        if os.path.isfile(rinputs):
            with open(rinputs, "rb") as f:
                inputs_list.append([int(b) for b in zlib.decompress(f.read())])
        else:
            break

#import map data
mdata_list = []
if tool_mode == "trace":
    with open(RAW_MAP_DATA, "rb") as f:
        mdata = [int(b) for b in f.read()]
    for _ in range(len(inputs_list)):
        mdata_list.append(mdata)
elif tool_mode == "splits":
    for rmdata in (RAW_MAP_DATA_EPISODE):
        with open(rmdata, "rb") as f:
            mdata_list.append([int(b) for b in f.read()])

#These dictionaries convert raw input data into the horizontal and jump components.
HOR_INPUTS_DIC = {0:0, 1:0, 2:1, 3:1, 4:-1, 5:-1, 6:-1, 7:-1}
JUMP_INPUTS_DIC = {0:0, 1:1, 2:0, 3:1, 4:0, 5:1, 6:0, 7:1}

goldlog = []
frameslog = []
validlog = []
collisionlog = []
entitylog = []

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
    goldlog.append(sim.gold_collected)
    frameslog.append(inp_len)
    validlog.append(valid)
    collisionlog.append(sim.collisionlog)
    poslog = array.array('h')
    for xpos, ypos in zip(sim.ninja.xposlog, sim.ninja.yposlog):
        poslog.append(pack_coord(xpos))
        poslog.append(pack_coord(ypos))
    entities = [(0, i, poslog)]
    entities += [(e.type, e.index, e.poslog) for l in sim.entity_dic.values() for e in l if e.log_positions]
    entitylog.append(entities)

            
#Export simulation result for outte (coordinates, collisions, ...)
if tool_mode == "trace":
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
                frames = round(len(entity[2]) / 2)
                f.write(struct.pack('<BHH', *entity[:2], frames))
                entity[2].tofile(f)
            # Collision section
            collisions = len(collisionlog[i])
            f.write(struct.pack('<L', collisions))
            for col in collisionlog[i]:
                f.write(col)
    print("%.3f" % ((90 * 60 - frameslog[0] + 1 + goldlog[0] * 120) / 60))

#For each level of the episode, write to file whether the replay is valid, then write the score split. 
#Only ran in splits mode.
if tool_mode == "splits":
    split = 90*60
    with open(OUTPUT_SPLITS, "w") as f:
        for i in range(5):
            print(validlog[i], file=f)
            split = split - frameslog[i] + 1 + goldlog[i]*120
            print(split, file=f)