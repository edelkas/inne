import cairo
import pygame
import math
import os.path
import struct

from nsim import *

def hex2float(string):
    value = int(string, 16)
    red = ((value & 0xFF0000) >> 16) / 255
    green = ((value & 0x00FF00) >> 8) / 255
    blue = (value & 0x0000FF) / 255
    return red, green, blue

width = 1056
height = 600

pygame.init()
pygame.display.set_caption("N++")
screen = pygame.display.set_mode((width, height))
clock = pygame.time.Clock()
running = True

sim = Simulator()
with open("map_data", "rb") as f:
    mapdata = [int(b) for b in f.read()]
sim.load(mapdata)

limbs = ((0, 12), (1, 12), (2, 8), (3, 9), (4, 10), (5, 11), (6, 7), (8, 0), (9, 0), (10, 1), (11, 1))

bgsurface = cairo.ImageSurface(cairo.Format.RGB24, width, height)
bgcontext = cairo.Context(bgsurface)

bgcontext.set_source_rgb(*hex2float("cbcad0"))
bgcontext.rectangle(0, 0, width, height)
bgcontext.fill()

bgcontext.set_source_rgb(*hex2float("797988"))
for coords, tile in sim.tile_dic.items():
    x, y = coords
    if tile == 1 or tile > 33:
        bgcontext.rectangle(x * 24, y * 24, 24, 24)
    elif tile > 1:
        if tile < 6:
            dx = 12 if tile == 3 else 0
            dy = 12 if tile == 4 else 0
            w = 24 if tile % 2 == 0 else 12
            h = 12 if tile % 2 == 0 else 24
            bgcontext.rectangle(x * 24 + dx, y * 24 + dy, w, h)
        elif tile < 10:
            dx1 = 0
            dy1 = 24 if tile == 8 else 0
            dx2 = 0 if tile == 9 else 24
            dy2 = 24 if tile == 9 else 0
            dx3 = 0 if tile == 6 else 24
            dy3 = 24
            bgcontext.move_to(x * 24 + dx1, y * 24 + dy1)
            bgcontext.line_to(x * 24 + dx2, y * 24 + dy2)
            bgcontext.line_to(x * 24 + dx3, y * 24 + dy3)
        elif tile < 14:
            dx = 24 if (tile == 11 or tile == 12) else 0
            dy = 24 if (tile == 12 or tile == 13) else 0
            a1 = (math.pi / 2) * (tile - 10)
            a2 = (math.pi / 2) * (tile - 9)
            bgcontext.move_to(x * 24 + dx, y * 24 + dy)
            bgcontext.arc(x * 24 + dx, y * 24 + dy, 24, a1, a2)
            bgcontext.line_to(x * 24 + dx, y * 24 + dy)
        elif tile < 18:
            dx1 = 24 if (tile == 15 or tile == 16) else 0
            dy1 = 24 if (tile == 16 or tile == 17) else 0
            dx2 = 24 if (tile == 14 or tile == 17) else 0
            dy2 = 24 if (tile == 14 or tile == 15) else 0
            a1 = math.pi + (math.pi / 2) * (tile - 10)
            a2 = math.pi + (math.pi / 2) * (tile - 9)
            bgcontext.move_to(x * 24 + dx1, y * 24 + dy1)
            bgcontext.arc(x * 24 + dx2, y * 24 + dy2, 24, a1, a2)
            bgcontext.line_to(x * 24 + dx1, y * 24 + dy1)
        elif tile < 22:
            dx1 = 0
            dy1 = 24 if (tile == 20 or tile == 21) else 0
            dx2 = 24
            dy2 = 24 if (tile == 20 or tile == 21) else 0
            dx3 = 24 if (tile == 19 or tile == 20) else 0
            dy3 = 12
            bgcontext.move_to(x * 24 + dx1, y * 24 + dy1)
            bgcontext.line_to(x * 24 + dx2, y * 24 + dy2)
            bgcontext.line_to(x * 24 + dx3, y * 24 + dy3)
        elif tile < 26:
            dx1 = 0
            dy1 = 12 if (tile == 23 or tile == 24) else 0
            dx2 = 0 if tile == 23 else 24
            dy2 = 12 if tile == 25 else 0
            dx3 = 24
            dy3 = (12 if tile == 22 else 0) if tile < 24 else 24
            dx4 = 24 if tile == 23 else 0
            dy4 = 24
            bgcontext.move_to(x * 24 + dx1, y * 24 + dy1)
            bgcontext.line_to(x * 24 + dx2, y * 24 + dy2)
            bgcontext.line_to(x * 24 + dx3, y * 24 + dy3)
            bgcontext.line_to(x * 24 + dx4, y * 24 + dy4)
        elif tile < 30:
            dx1 = 12
            dy1 = 24 if (tile == 28 or tile == 29) else 0
            dx2 = 24 if (tile == 27 or tile == 28) else 0
            dy2 = 0
            dx3 = 24 if (tile == 27 or tile == 28) else 0
            dy3 = 24
            bgcontext.move_to(x * 24 + dx1, y * 24 + dy1)
            bgcontext.line_to(x * 24 + dx2, y * 24 + dy2)
            bgcontext.line_to(x * 24 + dx3, y * 24 + dy3)
        elif tile < 34:
            dx1 = 12
            dy1 = 24 if (tile == 30 or tile == 31) else 0
            dx2 = 24 if (tile == 31 or tile == 33) else 0
            dy2 = 24
            dx3 = 24 if (tile == 31 or tile == 32) else 0
            dy3 = 24 if (tile == 32 or tile == 33) else 0
            dx4 = 24 if (tile == 30 or tile == 32) else 0
            dy4 = 0
            bgcontext.move_to(x * 24 + dx1, y * 24 + dy1)
            bgcontext.line_to(x * 24 + dx2, y * 24 + dy2)
            bgcontext.line_to(x * 24 + dx3, y * 24 + dy3)
            bgcontext.line_to(x * 24 + dx4, y * 24 + dy4)
    bgcontext.fill()

bgbuffer = bgsurface.get_data()
bgimage = pygame.image.frombuffer(bgbuffer, (width, height), "BGRA")

fgsurface = cairo.ImageSurface(cairo.Format.RGB24, width, height)
fgcontext = cairo.Context(fgsurface)

while running:
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False
    
    keys = pygame.key.get_pressed()
    hor_input = 0
    jump_input = 0
    if keys[pygame.K_RIGHT]:
        hor_input = 1
    if keys[pygame.K_LEFT]:
        hor_input = -1
    if keys[pygame.K_z]:
        jump_input = 1
    if keys[pygame.K_SPACE]:
        sim.load(mapdata)

    fgcontext.set_operator(cairo.Operator.CLEAR)
    fgcontext.rectangle(0, 0, width, height)
    fgcontext.fill()
    fgcontext.set_operator(cairo.Operator.OVER)

    fgcontext.set_source_rgb(*hex2float("797988"))
    fgcontext.set_line_width(2)
    for cell in sim.segment_dic.values():
        for segment in cell:
            if segment.active and segment.type == "linear" and not segment.oriented:
                fgcontext.move_to(segment.x1, segment.y1)
                fgcontext.line_to(segment.x2, segment.y2)
        fgcontext.stroke()
    
    fgcontext.set_source_rgb(*hex2float("882276"))
    fgcontext.set_line_width(3)
    for entity in sim.entity_list:
        if entity.active:
            if hasattr(entity, "normal_x") and hasattr(entity, "normal_y"):
                if hasattr(entity, "RADIUS"):
                    radius = entity.RADIUS
                if hasattr(entity, "SEMI_SIDE"):
                    radius = entity.SEMI_SIDE
                angle = math.atan2(entity.normal_x, entity.normal_y) + math.pi / 2
                fgcontext.move_to(entity.xpos + math.sin(angle) * radius, entity.ypos + math.cos(angle) * radius)
                fgcontext.line_to(entity.xpos - math.sin(angle) * radius, entity.ypos - math.cos(angle) * radius)
                fgcontext.stroke()
            elif not hasattr(entity, "orientation") or entity.is_physical_collidable:
                if hasattr(entity, "RADIUS"):
                    fgcontext.arc(entity.xpos, entity.ypos, entity.RADIUS, 0, 2 * math.pi)
                    fgcontext.fill()
                elif hasattr(entity, "SEMI_SIDE"):
                    fgcontext.rectangle(entity.xpos - entity.SEMI_SIDE, entity.ypos - entity.SEMI_SIDE, entity.SEMI_SIDE * 2, entity.SEMI_SIDE * 2)
                    fgcontext.fill()

    fgcontext.set_source_rgb(*hex2float("000000"))
    fgcontext.set_source_rgb(0, 0, 0)
    fgcontext.set_line_width(1)
    bones = sim.ninja.bones
    segments = [[bones[limb[0]], bones[limb[1]]] for limb in limbs]
    for segment in segments:
        x1 = segment[0][0]*2*sim.ninja.RADIUS + sim.ninja.xpos
        y1 = segment[0][1]*2*sim.ninja.RADIUS + sim.ninja.ypos
        x2 = segment[1][0]*2*sim.ninja.RADIUS + sim.ninja.xpos
        y2 = segment[1][1]*2*sim.ninja.RADIUS + sim.ninja.ypos
        fgcontext.move_to(x1, y1)
        fgcontext.line_to(x2, y2)
        fgcontext.stroke()

    fgbuffer = fgsurface.get_data()
    fgimage = pygame.image.frombuffer(fgbuffer, (width, height), "BGRA")

    screen.blit(bgimage, (0, 0))
    screen.blit(fgimage, (0, 0))

    sim.tick(hor_input, jump_input)

    pygame.display.flip()
    clock.tick(60)

pygame.quit()