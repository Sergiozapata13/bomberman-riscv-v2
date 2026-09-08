# ================================================================
# Bomberman ASM - Reescritura completa
# EL-3310 Diseno de Sistemas Digitales
# Arquitectura: RISC-V (RARS)
#
# Configuracion del Bitmap Display (RARS Tools):
#   Unit Width in Pixels:  8
#   Unit Height in Pixels: 8
#   Display Width:         512
#   Display Height:        512
#   Base address:          gp (Global Pointer)
#
# Configuracion del Keyboard and Display MMIO Simulator:
#   Debe estar conectado junto con el Bitmap Display
#
# Controles:
#   W = arriba, S = abajo, A = izquierda, D = derecha
#   (el resto de controles se agregan en etapas posteriores)
#
# ================================================================
# ETAPA 0: Infraestructura base
#   - Constantes del sistema (pantalla, tiles, colores, MMIO)
#   - Rutinas de framebuffer: limpiar_pantalla, pintar_unidad,
#     calcular_posicion_fb, pintar_bloque
#   - Checkpoint visual: pintar un bloque de prueba en pantalla
# ================================================================

# ----------------------------------------------------------------
# Memory-mapped I/O (teclado)
# Referencia: https://www.it.uu.se/education/course/homepage/os/vt18/module-1/memory-mapped-io/
# ----------------------------------------------------------------
.eqv KEY_STATUS_ADDRESS  0xFFFF0000
.eqv KEY_INPUT_ADDRESS   0xFFFF0004

# ----------------------------------------------------------------
# Codigos ASCII de teclas usadas
# ----------------------------------------------------------------
.eqv ASCII_W   119   # arriba
.eqv ASCII_S   115   # abajo
.eqv ASCII_A   97    # izquierda
.eqv ASCII_D   100   # derecha
.eqv ASCII_SPACE 32  # colocar bomba

# ----------------------------------------------------------------
# Geometria de pantalla y tiles
# ----------------------------------------------------------------
# IMPORTANTE: con el Bitmap Display de RARS configurado en
# Unit Width/Height = 8px y Display 512x512, cada WORD del
# framebuffer representa una "unidad" de 8x8 px en pantalla, NO
# un pixel individual. La grilla real en memoria es de 64x64
# unidades (512/8 = 64).
#
# Para simplificar el resto del codigo, trabajamos siempre en
# "unidades de framebuffer" (fb-units) de 8x8px como si fueran
# el pixel logico mas pequeno que podemos dibujar. Un TILE de
# juego (32x32 px reales) equivale entonces a 4x4 fb-units.
# ----------------------------------------------------------------
.eqv FB_UNIDADES_LADO       64     # 512/8, ancho y alto en unidades
.eqv FB_TOTAL_UNIDADES     4096    # 64*64, total de words del framebuffer
.eqv FB_ANCHO_SHIFT           6    # log2(64), para offset = y*64+x

.eqv TILE_SIZE                4    # tamano de cada celda de juego en fb-units (32px reales / 8px por unidad)
.eqv TILE_SHIFT               2    # log2(4), para usar shifts en vez de mult/div
.eqv MAPA_COLUMNAS           16    # 64/4
.eqv MAPA_FILAS              16    # 64/4
.eqv MAPA_COL_SHIFT            4   # log2(16), para indexar fila*16 con shift

.eqv HITBOX_SIZE               4   # hitbox del jugador/enemigos = TILE_SIZE completo (sin margen).
                                    # NOTA: originalmente se probo un hitbox reducido (2, con
                                    # margen 1) para permitir "resbalar" en pasillos angostos como
                                    # el Bomberman original. Se revirtio a hitbox completo porque el
                                    # sprite dibujado (siempre TILE_SIZE=4) quedaba mas grande que
                                    # el hitbox validado, y eso causaba solape visual: el jugador
                                    # se dibujaba montado sobre el bloque vecino antes de que la
                                    # colision lo detectara. La consecuencia de este cambio es que
                                    # el jugador ahora SI se traba contra esquinas de pasillos de
                                    # una celda de ancho (pierde el "resbale" natural). Si se
                                    # quiere recuperar ese resbale sin reintroducir el solape
                                    # visual, la alternativa es dibujar el sprite del mismo tamano
                                    # que el hitbox (ver conversacion de diseno).
.eqv HITBOX_MARGEN              0  # sin margen: el hitbox ocupa el tile completo, (TILE_SIZE-HITBOX_SIZE)/2 = 0

.eqv JUGADOR_VELOCIDAD    TILE_SIZE  # fb-unidades por movimiento = un tile completo (4).
                                     # Se cambio de 1 (movimiento suave pixel a pixel) a
                                     # TILE_SIZE porque el movimiento fraccionario generaba un
                                     # conflicto de fondo: el jugador ocupaba parte de dos tiles
                                     # a la vez, pero el resto del sistema (mapa, bombas,
                                     # explosiones) dibuja y verifica en tiles completos
                                     # alineados a grilla -- eso causaba restos de sprite sin
                                     # limpiar (franjas cian sueltas) cuando una bomba/explosion
                                     # aparecia en un tile vecino mientras el jugador estaba a
                                     # medio camino. Con saltos de tile completo, el jugador
                                     # siempre esta perfectamente alineado, eliminando el
                                     # conflicto de raiz (a costa del deslizamiento suave que
                                     # se buscaba originalmente).

# ----------------------------------------------------------------
# Bombas y explosiones (Etapa 3)
# ----------------------------------------------------------------
.eqv MAX_BOMBAS               8    # bombas activas simultaneas (con powerup de bomba extra)
.eqv MAX_EXPLOSIONES         40    # celdas de fuego activas simultaneas. Subido de 16 a 40:
                                    # con rango 1, cada bomba genera hasta 5 celdas de fuego
                                    # (centro + 4 direcciones); con las MAX_BOMBAS=8 explotando
                                    # en cadena casi al mismo tiempo, se necesitan hasta 8*5=40
                                    # slots simultaneos en el peor caso. Con 16 el limite se
                                    # agotaba a mitad de una cadena grande (el fuego dejaba de
                                    # verse en las ultimas celdas, aunque gracias al arreglo de
                                    # redibujar_celda en explotar_bomba/explotar_direccion ya no
                                    # quedaban bombas fantasma pegadas en pantalla).
.eqv BOMBA_TIMER_INICIAL    400    # "ticks" del loop principal antes de explotar (subido de 120,
                                   # que se sentia demasiado corto). NOTA: sigue siendo una
                                   # aproximacion sin medir FPS real -- calibrar jugando, igual
                                   # que FRAME_DELAY_CICLOS.
.eqv EXPLOSION_TIMER_INICIAL 30   # ticks que dura visible cada celda de fuego antes de apagarse
.eqv JUGADOR_RANGO_INICIAL     1  # celdas de alcance de la explosion en cada direccion desde el centro (antes de powerup de llama)

.eqv FRAME_DELAY_CICLOS      5000  # iteraciones del busy-wait de esperar_frame; calibrar a gusto (mas alto = mas lento/estable, mas bajo = mas rapido). Bajado de 300000 tras pasar a redibujado parcial (Etapa 2): con mucho menos trabajo por frame, un delay tan alto se sentia innecesariamente lento.

# ----------------------------------------------------------------
# Colores en formato 0x00RRGGBB
# ----------------------------------------------------------------
.eqv COLOR_NEGRO         0x00000000
.eqv COLOR_BLANCO        0x00FFFFFF
.eqv COLOR_ROJO          0x00FF0000
.eqv COLOR_VERDE         0x0000FF00
.eqv COLOR_AZUL          0x000000FF
.eqv COLOR_LADRILLO      0x00E86F00   # bloque destructible
.eqv COLOR_ACERO         0x00B0B0B0   # bloque indestructible
.eqv COLOR_AMARILLO      0x00FFD000   # salida / detalles
.eqv COLOR_JUGADOR       0x0000FFFF   # cian, temporal para checkpoint visual

# ----------------------------------------------------------------
# Tipos de celda del mapa (bits [7:0] de la word de celda)
# ----------------------------------------------------------------
.eqv CELDA_VACIA             0
.eqv CELDA_INDESTRUCTIBLE    1
.eqv CELDA_DESTRUCTIBLE      2
.eqv CELDA_SALIDA            3
.eqv CELDA_BOMBA             4    # celda ocupada por una bomba activa (bloquea movimiento del jugador)
.eqv CELDA_EXPLOSION         5    # celda con fuego activo (bloquea movimiento y mata si el jugador la pisa -- se implementa en Etapa 4)

# Power-up oculto bajo bloque destructible (bits [15:8] de la word de celda)
.eqv POWERUP_NINGUNO         0
.eqv POWERUP_LLAMA           1
.eqv POWERUP_BOMBA_EXTRA     2
.eqv POWERUP_PATIN           3
.eqv POWERUP_SALIDA_OCULTA   4   # revela CELDA_SALIDA al destruir el bloque


.data
# ----------------------------------------------------------------
# Mapa del Nivel 1 (16x16 celdas). Cada word empaca:
#   bits [7:0]   = tipo de terreno (VACIA=0, INDESTRUCTIBLE=1,
#                  DESTRUCTIBLE=2, SALIDA=3)
#   bits [15:8]  = power-up oculto bajo el bloque destructible
#                  (NINGUNO=0, LLAMA=1, BOMBA_EXTRA=2, PATIN=3,
#                  SALIDA_OCULTA=4)
#
# Los valores estan pre-calculados como literales (tipo | (pu<<8))
# en vez de usar expresiones dentro de .word, porque RARS no
# garantiza soporte de expresiones aritmeticas en directivas de
# datos (ver github.com/TheThirdOne/rars/issues/217, abierto).
#
# Patron: borde exterior indestructible, ajedrez interior de
# indestructibles en (fila par, col par) para fila,col en 2..12,
# resto de celdas libres pobladas ~60% con destructibles. Salida
# oculta en (14,14). Power-ups ocultos: LLAMA en (1,12),
# BOMBA_EXTRA en (7,7), PATIN en (11,3). Zona de spawn del
# jugador (1,1),(1,2),(2,1) despejada.
# ----------------------------------------------------------------
mapa_nivel:
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1
    .word   1,  0,  0,  0,  2,  2,  2,  0,  0,  0,  2,  2,258,  2,  2,  1
    .word   1,  0,  1,  2,  1,  2,  1,  0,  1,  2,  1,  2,  1,  2,  1,  1
    .word   1,  0,  2,  0,  0,  2,  2,  0,  2,  2,  2,  0,  0,  0,  0,  1
    .word   1,  2,  1,  0,  1,  2,  1,  2,  1,  0,  1,  0,  1,  0,  1,  1
    .word   1,  2,  0,  2,  2,  2,  2,  2,  2,  2,  0,  2,  2,  2,  2,  1
    .word   1,  0,  1,  0,  1,  0,  1,  2,  1,  0,  1,  2,  1,  2,  1,  1
    .word   1,  0,  0,  2,  0,  0,  0,514,  2,  2,  2,  2,  0,  0,  2,  1
    .word   1,  0,  1,  2,  1,  0,  1,  2,  1,  2,  1,  2,  1,  2,  1,  1
    .word   1,  2,  2,  0,  2,  2,  0,  2,  2,  2,  2,  0,  0,  2,  2,  1
    .word   1,  2,  1,  0,  1,  2,  1,  0,  1,  0,  1,  2,  1,  0,  1,  1
    .word   1,  0,  2,770,  0,  2,  2,  2,  0,  0,  2,  2,  2,  0,  0,  1
    .word   1,  2,  1,  0,  1,  0,  1,  2,  1,  0,  1,  2,  1,  0,  1,  1
    .word   1,  2,  2,  2,  2,  0,  0,  0,  2,  2,  0,  0,  2,  2,  2,  1
    .word   1,  0,  1,  0,  1,  2,  1,  2,  1,  2,  1,  2,  1,  0,1026,  1
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1


# ----------------------------------------------------------------
# Posicion del jugador, en fb-unidades absolutas (esquina superior
# izquierda del sprite de 1 tile = TILE_SIZE fb-unidades). Spawn
# inicial: tile (1,1) -> fb-unidad (4,4) porque TILE_SIZE=4.
# ----------------------------------------------------------------
jugador_x: .word 4
jugador_y: .word 4
jugador_rango: .word JUGADOR_RANGO_INICIAL


# ----------------------------------------------------------------
# Tabla de bombas activas (arrays paralelos, MAX_BOMBAS slots).
# bomba_activa[i] = 0 significa slot libre; 1 significa ocupado.
# ----------------------------------------------------------------
bomba_activa: .word 0:8    # MAX_BOMBAS
bomba_col:    .word 0:8
bomba_fila:   .word 0:8
bomba_timer:  .word 0:8
bomba_rango:  .word 0:8

# ----------------------------------------------------------------
# Tabla de explosiones activas (arrays paralelos, MAX_EXPLOSIONES
# slots). Cada slot representa UNA celda de fuego individual (no
# una bomba completa -- una bomba de rango 1 genera hasta 5 slots:
# el centro + 1 celda en cada una de las 4 direcciones, menos las
# que se corten contra un bloque indestructible).
# ----------------------------------------------------------------
explosion_activa: .word 0:40   # MAX_EXPLOSIONES
explosion_col:    .word 0:40
explosion_fila:   .word 0:40
explosion_timer:  .word 0:40
explosion_revela_salida: .word 0:40   # 1 si al apagarse esta celda debe quedar CELDA_SALIDA en vez de CELDA_VACIA


.text
main:
    jal  limpiar_pantalla
    jal  pintar_mapa

    # Dibujar al jugador en su posicion inicial de spawn (fuera del
    # loop, se pinta una sola vez aqui; despues solo se redibuja
    # si realmente se mueve, ver loop_principal).
    lw   a0, jugador_x
    lw   a1, jugador_y
    li   a2, COLOR_JUGADOR
    li   a3, TILE_SIZE
    li   a4, TILE_SIZE
    jal  pintar_bloque_fb

loop_principal:
    # --- Actualizaciones que corren TODOS los frames, con o sin
    #     tecla presionada (los timers avanzan con el tiempo) ---
    jal  actualizar_bombas
    jal  actualizar_explosiones

    # --- Leer input ---
    li   t0, KEY_STATUS_ADDRESS
    lw   t1, 0(t0)
    beqz t1, loop_principal_colisiones

    li   t0, KEY_INPUT_ADDRESS
    lw   t1, 0(t0)
    li   t2, ASCII_SPACE
    beq  t1, t2, main_colocar_bomba

    # Guardar posicion actual (antes de mover), en coordenadas de
    # TILE (no fb-unidades), para poder redibujar el tile viejo
    # despues. Con JUGADOR_VELOCIDAD=TILE_SIZE, el jugador siempre
    # esta alineado a tile antes y despues de moverse.
    lw   t0, jugador_x
    srai s0, t0, TILE_SHIFT    # columna de tile vieja
    lw   t0, jugador_y
    srai s1, t0, TILE_SHIFT    # fila de tile vieja

    jal  mover_jugador          # retorna a0=1 si se movio

    li   t0, KEY_STATUS_ADDRESS
    sw   zero, 0(t0)            # limpiar estado del teclado tras procesarlo

    beqz a0, loop_principal_colisiones     # no se movio -> nada que redibujar

    # Redibujar el tile VIEJO (el jugador ya no esta ahi, se pinta
    # segun lo que realmente contenga esa celda) y el tile NUEVO
    # (donde ahora esta parado, redibujar_celda ya sabe pintarlo
    # con COLOR_JUGADOR porque jugador_esta_en_celda lo detecta).
    mv   a0, s0
    mv   a1, s1
    jal  redibujar_celda

    lw   t0, jugador_x
    srai a0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai a1, t0, TILE_SHIFT
    jal  redibujar_celda

    j    loop_principal_colisiones

main_colocar_bomba:
    jal  colocar_bomba

    li   t0, KEY_STATUS_ADDRESS
    sw   zero, 0(t0)            # limpiar estado del teclado tras procesarlo

loop_principal_colisiones:
    # --- Resolver colisiones entre entidades (Etapa 4 en adelante):
    #     jugador vs fuego, jugador vs enemigo, etc. Se ubica aqui,
    #     despues de que el jugador ya se movio y las bombas/
    #     explosiones ya se actualizaron este frame, para que el
    #     chequeo vea el estado final y consistente del frame. Por
    #     ahora vacio; se completa en la Etapa 4. ---

loop_principal_fin_de_vuelta:
    jal  esperar_frame
    j    loop_principal

fin_programa:
    j fin_programa


# ================================================================
# Funcion: limpiar_pantalla
# Llena todo el framebuffer (512x512 = 262144 pixeles) con negro.
# Parametros: ninguno
# Retorno: void
# ================================================================
limpiar_pantalla:
    mv   t0, gp
    li   t1, FB_TOTAL_UNIDADES
    li   t2, COLOR_NEGRO

limpiar_pantalla_loop:
    sw   t2, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -1
    bnez t1, limpiar_pantalla_loop
    ret


# ================================================================
# Funcion: esperar_frame
# Busy-wait simple para regular la velocidad del game loop. Sin
# este freno, RARS ejecuta el loop principal a la maxima velocidad
# de la maquina host, dibujando y borrando la pantalla tantas
# veces por segundo que el ojo humano solo percibe parpadeo -- no
# alcanza a fijar ningun frame individual antes de que el
# siguiente ya lo haya sobreescrito.
# Parametros: ninguno
# Retorno: void
# ================================================================
esperar_frame:
    li   t0, FRAME_DELAY_CICLOS

esperar_frame_loop:
    addi t0, t0, -1
    bnez t0, esperar_frame_loop
    ret


# ================================================================
# Funcion: calcular_posicion_fb
# Calcula la direccion de memoria de una "unidad" de framebuffer
# dada su coordenada (x,y) EN UNIDADES DE 8x8 PX (0-63), no en
# pixeles reales.
# Parametros:
#   a0: x en fb-unidades (0-63)
#   a1: y en fb-unidades (0-63)
# Retorno:
#   a0: direccion en el framebuffer
# ================================================================
calcular_posicion_fb:
    slli t0, a1, FB_ANCHO_SHIFT  # t0 = y * 64
    add  t1, a0, t0              # t1 = y*64 + x  (offset en unidades)
    slli t1, t1, 2                # t1 = offset en bytes (*4)
    add  a0, t1, gp
    ret


# ================================================================
# Funcion: pintar_unidad
# Pinta una sola "unidad" de framebuffer (bloque de 8x8 px en
# pantalla).
# Parametros:
#   a0: x en fb-unidades (0-63)
#   a1: y en fb-unidades (0-63)
#   a2: color (0x00RRGGBB)
# Retorno: void
# ================================================================
pintar_unidad:
    addi sp, sp, -8
    sw   ra, 0(sp)
    sw   s0, 4(sp)

    mv   s0, a2
    jal  calcular_posicion_fb
    sw   s0, 0(a0)

    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 8
    ret


# ================================================================
# Funcion: pintar_bloque_fb
# Rellena un rectangulo en coordenadas de FB-UNIDADES (bloques de
# 8x8 px).
# Parametros:
#   a0: x (esquina superior izquierda, fb-unidades)
#   a1: y (esquina superior izquierda, fb-unidades)
#   a2: color
#   a3: ancho en fb-unidades
#   a4: alto en fb-unidades
# Retorno: void
# ================================================================
pintar_bloque_fb:
    addi sp, sp, -32
    sw   ra, 0(sp)
    sw   s0, 4(sp)      # x base
    sw   s1, 8(sp)      # y actual
    sw   s2, 12(sp)     # color
    sw   s3, 16(sp)     # ancho
    sw   s4, 20(sp)     # filas restantes
    sw   s5, 24(sp)     # x actual (columna)
    sw   s6, 28(sp)     # columnas restantes en la fila actual

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2
    mv   s3, a3
    mv   s4, a4

pintar_bloque_fb_fila:
    beqz s4, pintar_bloque_fb_fin

    mv   s5, s0
    mv   s6, s3          # columnas restantes en esta fila
                          # (s6 es callee-saved: sobrevive el jal de abajo,
                          #  a diferencia de un temporal t0-t6)

pintar_bloque_fb_col:
    beqz s6, pintar_bloque_fb_col_fin

    mv   a0, s5
    mv   a1, s1
    mv   a2, s2
    jal  pintar_unidad

    addi s5, s5, 1
    addi s6, s6, -1
    j    pintar_bloque_fb_col

pintar_bloque_fb_col_fin:
    addi s1, s1, 1
    addi s4, s4, -1
    j    pintar_bloque_fb_fila

pintar_bloque_fb_fin:
    lw   s6, 28(sp)
    lw   s5, 24(sp)
    lw   s4, 20(sp)
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 32
    ret


# ================================================================
# Funcion: pintar_bloque_tiles
# Igual que pintar_bloque_fb, pero recibe coordenadas y tamano en
# TILES de juego (4x4 fb-unidades = 32x32 px reales) en vez de
# fb-unidades directas. Conveniente para pintar el mapa de nivel
# usando coordenadas de grilla de juego.
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
#   a2: color
#   a3: ancho en tiles
#   a4: alto en tiles
# Retorno: void
# ================================================================
pintar_bloque_tiles:
    addi sp, sp, -4
    sw   ra, 0(sp)

    slli a0, a0, TILE_SHIFT      # columna -> fb-unidad x
    slli a1, a1, TILE_SHIFT      # fila -> fb-unidad y
    slli a3, a3, TILE_SHIFT      # ancho en tiles -> fb-unidades
    slli a4, a4, TILE_SHIFT      # alto en tiles -> fb-unidades
    jal  pintar_bloque_fb

    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: celda_color
# Traduce el tipo de celda (bits [7:0] de una word de mapa) a su
# color de dibujo. La SALIDA se pinta como si fuera destructible
# (el jugador no debe verla hasta que se revele destruyendo el
# bloque que la oculta -- eso se implementa en la Etapa 3).
# Parametros:
#   a0: word de celda completa (tipo + power-up empacados)
# Retorno:
#   a0: color (0x00RRGGBB)
# ================================================================
celda_color:
    andi t0, a0, 0xFF        # extraer tipo (bits bajos)

    li   t1, CELDA_INDESTRUCTIBLE
    beq  t0, t1, celda_color_indestructible
    li   t1, CELDA_DESTRUCTIBLE
    beq  t0, t1, celda_color_destructible
    li   t1, CELDA_SALIDA
    beq  t0, t1, celda_color_salida
    li   t1, CELDA_BOMBA
    beq  t0, t1, celda_color_bomba
    li   t1, CELDA_EXPLOSION
    beq  t0, t1, celda_color_explosion

    # CELDA_VACIA (o cualquier otro valor no reconocido)
    li   a0, COLOR_NEGRO
    ret

celda_color_indestructible:
    li   a0, COLOR_ACERO
    ret

celda_color_destructible:
    li   a0, COLOR_LADRILLO
    ret

celda_color_salida:
    li   a0, COLOR_AMARILLO
    ret

celda_color_bomba:
    li   a0, COLOR_ROJO
    ret

celda_color_explosion:
    li   a0, COLOR_BLANCO
    ret


# ================================================================
# Funcion: jugador_esta_en_celda
# Verifica si el jugador esta actualmente parado exactamente sobre
# la celda de tile (columna, fila) dada. Se usa para decidir
# prioridad de dibujo: si el jugador esta ahi, su sprite debe
# verse por encima de bombas/explosiones/terreno.
# Parametros:
#   a0: columna de tile a consultar
#   a1: fila de tile a consultar
# Retorno:
#   a0: 1 si el jugador esta en esa celda, 0 si no
# ================================================================
jugador_esta_en_celda:
    lw   t0, jugador_x
    srai t0, t0, TILE_SHIFT
    bne  t0, a0, jugador_esta_en_celda_no

    lw   t0, jugador_y
    srai t0, t0, TILE_SHIFT
    bne  t0, a1, jugador_esta_en_celda_no

    li   a0, 1
    ret

jugador_esta_en_celda_no:
    li   a0, 0
    ret


# ================================================================
# Funcion: redibujar_celda
# Punto UNICO de dibujo para una celda de tile completa: consulta,
# en orden de prioridad, que ocupa esa celda ahora mismo (jugador
# primero, despues lo que diga el mapa logico -- terreno, bomba,
# o explosion, segun el tipo almacenado en mapa_nivel) y pinta el
# color correspondiente. Todos los sistemas (colocar bomba,
# explotar bomba, apagar explosion, mover jugador) deben llamar
# esta funcion en vez de pintar directamente, para que ningun
# sistema tape a otro por accidente.
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void
# ================================================================
redibujar_celda:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)   # columna
    sw   s1, 8(sp)   # fila

    mv   s0, a0
    mv   s1, a1

    mv   a0, s0
    mv   a1, s1
    jal  jugador_esta_en_celda
    bnez a0, redibujar_celda_jugador

    mv   a0, s0
    mv   a1, s1
    jal  celda_tipo
    jal  celda_color        # a0 ya trae el tipo, celda_color lo interpreta directo
    j    redibujar_celda_pintar

redibujar_celda_jugador:
    li   a0, COLOR_JUGADOR

redibujar_celda_pintar:
    mv   a2, a0
    mv   a0, s0
    mv   a1, s1
    li   a3, 1
    li   a4, 1
    jal  pintar_bloque_tiles

    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: pintar_mapa
# Recorre las MAPA_FILAS*MAPA_COLUMNAS celdas de mapa_nivel y
# dibuja cada una segun su tipo de terreno.
# Parametros: ninguno
# Retorno: void
# ================================================================
pintar_mapa:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)      # puntero a la celda actual de mapa_nivel
    sw   s1, 8(sp)      # fila actual
    sw   s2, 12(sp)     # columna actual
    sw   s3, 16(sp)     # word de la celda actual

    la   s0, mapa_nivel
    li   s1, 0           # fila = 0

pintar_mapa_fila:
    li   t0, MAPA_FILAS
    bge  s1, t0, pintar_mapa_fin

    li   s2, 0           # columna = 0

pintar_mapa_col:
    li   t0, MAPA_COLUMNAS
    bge  s2, t0, pintar_mapa_col_fin

    lw   s3, 0(s0)        # leer word de celda

    mv   a0, s3
    jal  celda_color       # a0 = color segun tipo de celda

    mv   a2, a0            # color para pintar_bloque_tiles
    mv   a0, s2            # columna de tile
    mv   a1, s1            # fila de tile
    li   a3, 1              # ancho 1 tile
    li   a4, 1              # alto 1 tile
    jal  pintar_bloque_tiles

    addi s0, s0, 4         # siguiente celda (4 bytes por word)
    addi s2, s2, 1
    j    pintar_mapa_col

pintar_mapa_col_fin:
    addi s1, s1, 1
    j    pintar_mapa_fila

pintar_mapa_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: celda_es_solida
# Consulta si la celda del mapa en (columna, fila) bloquea el
# movimiento. Coordenadas fuera de rango (0..15) se consideran
# solidas (equivale a un muro invisible en el borde del mundo,
# proteccion extra ademas del borde INDESTRUCTIBLE ya presente
# en el mapa).
# Parametros:
#   a0: columna de tile (puede ser negativa o >=16)
#   a1: fila de tile (puede ser negativa o >=16)
# Retorno:
#   a0: 1 si solida (bloquea), 0 si libre
# ================================================================
celda_es_solida:
    # Chequeo de rango: columna
    blt   a0, zero, celda_es_solida_si
    li    t2, MAPA_COLUMNAS
    bge   a0, t2, celda_es_solida_si
    # Chequeo de rango: fila
    blt   a1, zero, celda_es_solida_si
    li    t2, MAPA_FILAS
    bge   a1, t2, celda_es_solida_si

    # offset = fila*MAPA_COLUMNAS + columna (en words -> *4 bytes)
    slli  t0, a1, MAPA_COL_SHIFT   # t0 = fila * 16
    add   t0, t0, a0                # t0 = fila*16 + columna
    slli  t0, t0, 2                 # t0 = offset en bytes
    la    t1, mapa_nivel
    add   t1, t1, t0
    lw    t1, 0(t1)
    andi  t1, t1, 0xFF              # tipo de celda (bits bajos)

    li    t2, CELDA_INDESTRUCTIBLE
    beq   t1, t2, celda_es_solida_si
    li    t2, CELDA_DESTRUCTIBLE
    beq   t1, t2, celda_es_solida_si

    # CELDA_VACIA o CELDA_SALIDA -> libre
    li    a0, 0
    ret

celda_es_solida_si:
    li    a0, 1
    ret


# ================================================================
# Funcion: hay_colision_mapa
# Revisa si el hitbox reducido del jugador/enemigo (HITBOX_SIZE
# fb-unidades, centrado con HITBOX_MARGEN dentro del tile de
# TILE_SIZE) choca con alguna celda solida, dada la esquina
# superior izquierda del SPRITE COMPLETO (no del hitbox) en
# fb-unidades absolutas.
# Parametros:
#   a0: x propuesto del sprite (esquina superior izq, fb-unidades)
#   a1: y propuesto del sprite (esquina superior izq, fb-unidades)
# Retorno:
#   a0: 1 si hay colision (solido), 0 si libre
# ================================================================
hay_colision_mapa:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)    # hitbox x (esquina sup-izq)
    sw   s1, 8(sp)    # hitbox y (esquina sup-izq)
    sw   s2, 12(sp)   # hitbox x + (HITBOX_SIZE-1) (esquina inferior der)
    sw   s3, 16(sp)   # hitbox y + (HITBOX_SIZE-1)

    addi s0, a0, HITBOX_MARGEN
    addi s1, a1, HITBOX_MARGEN
    addi s2, s0, HITBOX_SIZE
    addi s2, s2, -1
    addi s3, s1, HITBOX_SIZE
    addi s3, s3, -1

    # Esquina superior izquierda: (s0, s1) en fb-unidades -> tile
    srai a0, s0, TILE_SHIFT
    srai a1, s1, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

    # Esquina superior derecha: (s2, s1)
    srai a0, s2, TILE_SHIFT
    srai a1, s1, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

    # Esquina inferior izquierda: (s0, s3)
    srai a0, s0, TILE_SHIFT
    srai a1, s3, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

    # Esquina inferior derecha: (s2, s3)
    srai a0, s2, TILE_SHIFT
    srai a1, s3, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

    li   a0, 0
    j    hay_colision_mapa_fin

hay_colision_mapa_si:
    li   a0, 1

hay_colision_mapa_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: mover_jugador
# Lee la tecla actualmente presionada (WASD) y mueve al jugador
# JUGADOR_VELOCIDAD fb-unidades en esa direccion, siempre que el
# movimiento propuesto no choque con una celda solida del mapa
# (hay_colision_mapa). Si hay colision, el jugador simplemente no
# se mueve en ese eje (permite "deslizar" contra la pared en vez
# de trabarse por completo si solo un eje esta bloqueado -- pero
# en esta version el movimiento es de a un eje por tecla, asi que
# el resultado practico es: se mueve o no se mueve, sin deslizar
# diagonalmente todavia).
# Parametros: ninguno (lee jugador_x/jugador_y y KEY_INPUT_ADDRESS)
# Retorno:
#   a0: 1 si el jugador efectivamente se movio, 0 si no (tecla no
#       reconocida o movimiento bloqueado por colision)
# ================================================================
# ================================================================
# Funcion: mover_jugador
# Lee la tecla actualmente presionada (WASD) y mueve al jugador
# JUGADOR_VELOCIDAD fb-unidades en esa direccion, siempre que el
# movimiento propuesto no choque con una celda solida del mapa
# (hay_colision_mapa). Si hay colision, el jugador simplemente no
# se mueve en ese eje.
# Parametros: ninguno (lee jugador_x/jugador_y y KEY_INPUT_ADDRESS)
# Retorno:
#   a0: 1 si el jugador efectivamente se movio, 0 si no (tecla no
#       reconocida o movimiento bloqueado por colision)
#   a1: delta x aplicado (-JUGADOR_VELOCIDAD, 0, o +JUGADOR_VELOCIDAD)
#   a2: delta y aplicado (-JUGADOR_VELOCIDAD, 0, o +JUGADOR_VELOCIDAD)
#       (a1/a2 solo son validos si a0=1; de lo contrario son 0)
# ================================================================
mover_jugador:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)     # x propuesto
    sw   s1, 8(sp)     # y propuesto
    sw   s2, 12(sp)    # delta x
    sw   s3, 16(sp)    # delta y

    lw   s0, jugador_x
    lw   s1, jugador_y
    li   s2, 0
    li   s3, 0

    li   t0, KEY_INPUT_ADDRESS
    lw   t1, 0(t0)

    li   t2, ASCII_W
    beq  t1, t2, mover_jugador_arriba
    li   t2, ASCII_S
    beq  t1, t2, mover_jugador_abajo
    li   t2, ASCII_A
    beq  t1, t2, mover_jugador_izquierda
    li   t2, ASCII_D
    beq  t1, t2, mover_jugador_derecha
    li   a0, 0
    j    mover_jugador_fin   # tecla no reconocida, no hacer nada

mover_jugador_arriba:
    li   s3, -JUGADOR_VELOCIDAD
    addi s1, s1, -JUGADOR_VELOCIDAD
    j    mover_jugador_validar

mover_jugador_abajo:
    li   s3, JUGADOR_VELOCIDAD
    addi s1, s1, JUGADOR_VELOCIDAD
    j    mover_jugador_validar

mover_jugador_izquierda:
    li   s2, -JUGADOR_VELOCIDAD
    addi s0, s0, -JUGADOR_VELOCIDAD
    j    mover_jugador_validar

mover_jugador_derecha:
    li   s2, JUGADOR_VELOCIDAD
    addi s0, s0, JUGADOR_VELOCIDAD
    j    mover_jugador_validar

mover_jugador_validar:
    mv   a0, s0
    mv   a1, s1
    jal  hay_colision_mapa
    bnez a0, mover_jugador_bloqueado   # colision -> descartar movimiento propuesto

    la   t0, jugador_x
    sw   s0, 0(t0)
    la   t0, jugador_y
    sw   s1, 0(t0)
    li   a0, 1
    mv   a1, s2
    mv   a2, s3
    j    mover_jugador_fin

mover_jugador_bloqueado:
    li   a0, 0
    li   a1, 0
    li   a2, 0

mover_jugador_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: buscar_slot_libre
# Recorre un array de "activo" (0=libre, 1=ocupado) buscando el
# primer indice libre. Utilidad generica compartida por bombas y
# explosiones.
# Parametros:
#   a0: direccion base del array de activos
#   a1: tamano del array (cantidad de slots)
# Retorno:
#   a0: indice del primer slot libre, o -1 si no hay ninguno
# ================================================================
buscar_slot_libre:
    mv   t0, a0        # puntero al array
    li   t1, 0          # indice actual

buscar_slot_libre_loop:
    bge  t1, a1, buscar_slot_libre_no_hay

    lw   t2, 0(t0)
    beqz t2, buscar_slot_libre_encontrado

    addi t0, t0, 4
    addi t1, t1, 1
    j    buscar_slot_libre_loop

buscar_slot_libre_encontrado:
    mv   a0, t1
    ret

buscar_slot_libre_no_hay:
    li   a0, -1
    ret


# ================================================================
# Funcion: colocar_bomba
# Coloca una bomba en la celda de tile donde esta parado el
# jugador actualmente, si hay un slot libre en la tabla de bombas
# y esa celda del mapa esta vacia (no se puede colocar sobre otra
# bomba ni sobre un bloque).
# Parametros: ninguno (lee jugador_x/y y jugador_rango)
# Retorno: void
# ================================================================
colocar_bomba:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)     # indice de slot libre
    sw   s1, 8(sp)     # columna de tile del jugador
    sw   s2, 12(sp)    # fila de tile del jugador
    sw   s3, 16(sp)    # rango del jugador

    lw   t0, jugador_x
    srai s1, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai s2, t0, TILE_SHIFT
    lw   s3, jugador_rango

    # Verificar que la celda del mapa bajo el jugador este vacia
    # (no colocar bomba sobre otra bomba ya existente)
    mv   a0, s1
    mv   a1, s2
    jal  celda_tipo
    li   t1, CELDA_VACIA
    bne  a0, t1, colocar_bomba_fin   # celda ocupada -> no se puede colocar

    la   a0, bomba_activa
    li   a1, MAX_BOMBAS
    jal  buscar_slot_libre
    mv   s0, a0
    blt  s0, zero, colocar_bomba_fin   # sin slots libres -> no se puede colocar

    # Llenar el slot encontrado
    la   t0, bomba_activa
    slli t1, s0, 2
    add  t0, t0, t1
    li   t2, 1
    sw   t2, 0(t0)

    la   t0, bomba_col
    add  t0, t0, t1
    sw   s1, 0(t0)

    la   t0, bomba_fila
    add  t0, t0, t1
    sw   s2, 0(t0)

    la   t0, bomba_timer
    add  t0, t0, t1
    li   t2, BOMBA_TIMER_INICIAL
    sw   t2, 0(t0)

    la   t0, bomba_rango
    add  t0, t0, t1
    sw   s3, 0(t0)

    # Marcar la celda del mapa como CELDA_BOMBA
    mv   a0, s1
    mv   a1, s2
    li   a2, CELDA_BOMBA
    jal  celda_set_tipo

    # Redibujar la celda: redibujar_celda decide el color correcto
    # (jugador si sigue parado ahi, o el color de bomba segun el
    # tipo de celda que acabamos de fijar).
    mv   a0, s1
    mv   a1, s2
    jal  redibujar_celda

colocar_bomba_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: celda_tipo
# Lee el tipo de terreno (bits [7:0]) de una celda del mapa dada
# su columna/fila de tile. A diferencia de celda_es_solida, esta
# funcion devuelve el tipo exacto (VACIA/INDESTRUCTIBLE/etc), no
# un booleano. No hace chequeo de rango -- se asume que quien
# llama ya valido columna/fila validas (0..15).
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno:
#   a0: tipo de celda (bits bajos de la word, 0-255)
# ================================================================
celda_tipo:
    slli t0, a1, MAPA_COL_SHIFT
    add  t0, t0, a0
    slli t0, t0, 2
    la   t1, mapa_nivel
    add  t1, t1, t0
    lw   t1, 0(t1)
    andi a0, t1, 0xFF
    ret


# ================================================================
# Funcion: celda_powerup_oculto
# Lee el power-up oculto (bits [15:8]) de una celda del mapa.
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno:
#   a0: power-up oculto (0-255)
# ================================================================
celda_powerup_oculto:
    slli t0, a1, MAPA_COL_SHIFT
    add  t0, t0, a0
    slli t0, t0, 2
    la   t1, mapa_nivel
    add  t1, t1, t0
    lw   t1, 0(t1)
    srli t1, t1, 8
    andi a0, t1, 0xFF
    ret


# ================================================================
# Funcion: celda_set_tipo
# Escribe un nuevo tipo de terreno en una celda del mapa,
# PRESERVANDO el power-up oculto que ya tuviera empacado en los
# bits altos (para no perder esa informacion al cambiar, por
# ejemplo, de DESTRUCTIBLE a VACIA tras una explosion).
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
#   a2: nuevo tipo de celda (0-255)
# Retorno: void
# ================================================================
celda_set_tipo:
    slli t0, a1, MAPA_COL_SHIFT
    add  t0, t0, a0
    slli t0, t0, 2
    la   t1, mapa_nivel
    add  t1, t1, t0

    lw   t2, 0(t1)
    li   t3, 0xFFFFFF00      # mascara para conservar bits [31:8]
    and  t2, t2, t3
    or   t2, t2, a2           # insertar nuevo tipo en bits [7:0]
    sw   t2, 0(t1)
    ret


# ================================================================
# Funcion: agregar_explosion_celda
# Agrega una celda de fuego a la tabla de explosiones activas
# (busca slot libre) y marca esa celda del mapa como
# CELDA_EXPLOSION. Si no hay slots libres, la celda simplemente
# no se agrega (limite alcanzado; no deberia pasar con
# MAX_EXPLOSIONES=16 y rango tipico 1-3, pero se protege igual).
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void
# ================================================================
agregar_explosion_celda:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)   # indice de slot
    sw   s1, 8(sp)   # columna
    sw   s2, 12(sp)  # fila
    sw   s3, 16(sp)  # (reservado)

    mv   s1, a0
    mv   s2, a1

    la   a0, explosion_activa
    li   a1, MAX_EXPLOSIONES
    jal  buscar_slot_libre
    mv   s0, a0
    blt  s0, zero, agregar_explosion_celda_fin   # sin slots -> descartar

    la   t0, explosion_activa
    slli t1, s0, 2
    add  t0, t0, t1
    li   t2, 1
    sw   t2, 0(t0)

    la   t0, explosion_col
    add  t0, t0, t1
    sw   s1, 0(t0)

    la   t0, explosion_fila
    add  t0, t0, t1
    sw   s2, 0(t0)

    la   t0, explosion_timer
    add  t0, t0, t1
    li   t2, EXPLOSION_TIMER_INICIAL
    sw   t2, 0(t0)

    la   t0, explosion_revela_salida
    add  t0, t0, t1
    sw   zero, 0(t0)    # inicializado en 0; marcar_explosion_revela_salida lo pone en 1 si corresponde

    mv   a0, s1
    mv   a1, s2
    li   a2, CELDA_EXPLOSION
    jal  celda_set_tipo

    mv   a0, s1
    mv   a1, s2
    jal  redibujar_celda

agregar_explosion_celda_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: marcar_explosion_revela_salida
# Busca, en la tabla de explosiones activas, el slot que
# corresponde a la celda (columna, fila) dada, y marca su campo
# explosion_revela_salida en 1. Se usa cuando un bloque
# destructible que ocultaba la salida se destruye: el fuego debe
# seguir viendose blanco mientras dure (ya fue agregado por
# agregar_explosion_celda antes de llegar aqui), pero cuando se
# apague, la celda debe quedar en CELDA_SALIDA en vez de
# CELDA_VACIA -- este campo es la forma en que
# actualizar_explosiones sabe cual de las dos corresponde.
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void (si no encuentra el slot, no hace nada -- no
#   deberia pasar porque se llama justo despues de agregarlo, pero
#   se protege igual por si agregar_explosion_celda no consiguio
#   slot por MAX_EXPLOSIONES agotado)
# ================================================================
marcar_explosion_revela_salida:
    la   t0, explosion_activa
    li   t1, 0

marcar_explosion_revela_salida_buscar:
    li   t2, MAX_EXPLOSIONES
    bge  t1, t2, marcar_explosion_revela_salida_fin

    slli t3, t1, 2
    add  t4, t0, t3
    lw   t5, 0(t4)
    beqz t5, marcar_explosion_revela_salida_siguiente

    la   t4, explosion_col
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, a0, marcar_explosion_revela_salida_siguiente

    la   t4, explosion_fila
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, a1, marcar_explosion_revela_salida_siguiente

    la   t4, explosion_revela_salida
    add  t4, t4, t3
    li   t5, 1
    sw   t5, 0(t4)
    ret

marcar_explosion_revela_salida_siguiente:
    addi t1, t1, 1
    j    marcar_explosion_revela_salida_buscar

marcar_explosion_revela_salida_fin:
    ret


# ================================================================
# Funcion: explotar_direccion
# Genera la explosion en UNA direccion desde el centro de la
# bomba, avanzando celda por celda hasta HITBOX_SIZE... (rango)
# celdas o hasta toparse con un obstaculo. Logica compartida por
# las 4 direcciones de explotar_bomba.
#   - CELDA_INDESTRUCTIBLE: detiene la explosion en esa direccion,
#     SIN agregar fuego en esa celda.
#   - CELDA_SALIDA: igual que CELDA_INDESTRUCTIBLE -- la salida ya
#     revelada es permanente, no puede volver a taparse ni
#     destruirse con explosiones posteriores.
#   - CELDA_DESTRUCTIBLE: agrega fuego en esa celda, destruye el
#     bloque (revela power-up oculto o SALIDA si correspondia), y
#     DETIENE la explosion en esa direccion (no sigue mas alla).
#   - CELDA_BOMBA: agrega fuego en esa celda (para que se vea) Y
#     encadena la explosion de esa otra bomba (si esta activa en
#     la tabla), pero DETIENE el avance en esa direccion (la otra
#     bomba genera su propia cruz independiente).
#   - CELDA_VACIA / CELDA_EXPLOSION: agrega fuego y continua a la
#     siguiente celda en esa direccion.
# Parametros:
#   a0: columna central de la bomba
#   a1: fila central de la bomba
#   a2: rango (cuantas celdas se extiende en esta direccion)
#   a3: delta columna por paso (-1, 0, o 1)
#   a4: delta fila por paso (-1, 0, o 1)
# Retorno: void
# ================================================================
explotar_direccion:
    addi sp, sp, -32
    sw   ra, 0(sp)
    sw   s0, 4(sp)    # columna actual
    sw   s1, 8(sp)    # fila actual
    sw   s2, 12(sp)   # pasos restantes
    sw   s3, 16(sp)   # delta columna
    sw   s4, 20(sp)   # delta fila
    sw   s5, 24(sp)   # tipo de celda actual

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2
    mv   s3, a3
    mv   s4, a4

explotar_direccion_loop:
    blez s2, explotar_direccion_fin

    add  s0, s0, s3     # avanzar una celda en la direccion
    add  s1, s1, s4

    # Chequeo de rango (no salir del mapa 0..15)
    blt  s0, zero, explotar_direccion_fin
    li   t0, MAPA_COLUMNAS
    bge  s0, t0, explotar_direccion_fin
    blt  s1, zero, explotar_direccion_fin
    li   t0, MAPA_FILAS
    bge  s1, t0, explotar_direccion_fin

    mv   a0, s0
    mv   a1, s1
    jal  celda_tipo
    mv   s5, a0

    li   t0, CELDA_INDESTRUCTIBLE
    beq  s5, t0, explotar_direccion_fin   # muro fijo -> corta sin agregar fuego

    li   t0, CELDA_SALIDA
    beq  s5, t0, explotar_direccion_fin   # salida ya revelada -> permanente, corta
                                           # sin agregar fuego (no se puede volver a
                                           # tapar ni destruir con explosiones)

    # Cualquier otro tipo: agregar fuego en esta celda
    mv   a0, s0
    mv   a1, s1
    jal  agregar_explosion_celda

    li   t0, CELDA_DESTRUCTIBLE
    beq  s5, t0, explotar_direccion_destruir

    li   t0, CELDA_BOMBA
    beq  s5, t0, explotar_direccion_cadena

    # CELDA_VACIA / CELDA_SALIDA / CELDA_EXPLOSION -> seguir avanzando
    addi s2, s2, -1
    j    explotar_direccion_loop

explotar_direccion_destruir:
    # Revelar power-up oculto (o SALIDA) antes de decidir que le
    # queda a la celda cuando el fuego se apague. La celda YA fue
    # marcada CELDA_EXPLOSION y redibujada blanca por la llamada a
    # agregar_explosion_celda de mas arriba (antes de llegar aqui)
    # -- eso es correcto, el fuego debe verse mientras dura. Este
    # bloque no debe recolorear nada ahora mismo; solo registra que
    # tipo de celda debe quedar cuando actualizar_explosiones apague
    # este fuego (VACIA por defecto, o SALIDA si corresponde).
    mv   a0, s0
    mv   a1, s1
    jal  celda_powerup_oculto

    li   t0, POWERUP_SALIDA_OCULTA
    bne  a0, t0, explotar_direccion_fin   # sin salida oculta: nada mas que hacer

    mv   a0, s0
    mv   a1, s1
    jal  marcar_explosion_revela_salida

    j    explotar_direccion_fin

explotar_direccion_cadena:
    # Buscar si hay una bomba activa en (s0,s1) y, si la hay,
    # forzar su timer a 0 para que actualizar_bombas la haga
    # explotar en la proxima pasada (evita explotar recursivamente
    # dentro de esta misma llamada, que complicaria el guardado de
    # registros; un timer en 0 se procesa en el siguiente tick del
    # loop principal, con un retraso de a lo sumo 1 frame).
    la   t0, bomba_activa
    li   t1, 0

explotar_direccion_cadena_buscar:
    li   t2, MAX_BOMBAS
    bge  t1, t2, explotar_direccion_fin   # no deberia pasar, pero por seguridad

    slli t3, t1, 2
    add  t4, t0, t3
    lw   t5, 0(t4)
    beqz t5, explotar_direccion_cadena_siguiente

    la   t4, bomba_col
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, s0, explotar_direccion_cadena_siguiente

    la   t4, bomba_fila
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, s1, explotar_direccion_cadena_siguiente

    # Encontrada: forzar timer a 0
    la   t4, bomba_timer
    add  t4, t4, t3
    sw   zero, 0(t4)
    j    explotar_direccion_fin   # esta direccion se detiene aqui (bomba encontrada)

explotar_direccion_cadena_siguiente:
    addi t1, t1, 1
    j    explotar_direccion_cadena_buscar

explotar_direccion_fin:
    lw   s5, 24(sp)
    lw   s4, 20(sp)
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 32
    ret


# ================================================================
# Funcion: explotar_bomba
# Genera la explosion completa (centro + 4 direcciones) de la
# bomba en el indice dado de la tabla de bombas, y libera su slot.
# Parametros:
#   a0: indice de la bomba en la tabla (0..MAX_BOMBAS-1)
# Retorno: void
# ================================================================
explotar_bomba:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)    # indice
    sw   s1, 8(sp)    # columna central
    sw   s2, 12(sp)   # fila central
    sw   s3, 16(sp)   # rango

    mv   s0, a0

    la   t0, bomba_col
    slli t1, s0, 2
    add  t0, t0, t1
    lw   s1, 0(t0)

    la   t0, bomba_fila
    add  t0, t0, t1
    lw   s2, 0(t0)

    la   t0, bomba_rango
    add  t0, t0, t1
    lw   s3, 0(t0)

    # Liberar el slot de la bomba y vaciar la celda del mapa donde
    # estaba parada (se agregara fuego ahi mismo con el centro).
    la   t0, bomba_activa
    add  t0, t0, t1
    sw   zero, 0(t0)

    mv   a0, s1
    mv   a1, s2
    li   a2, CELDA_VACIA
    jal  celda_set_tipo

    # Redibujar esta celda de inmediato, sin depender de si
    # agregar_explosion_celda (abajo) consigue slot o no -- si el
    # limite MAX_EXPLOSIONES esta agotado, la celda igual debe
    # reflejar visualmente que ya no hay una bomba aqui (bug
    # encontrado: antes, si agregar_explosion_celda fallaba por
    # falta de slot, el sprite rojo de la bomba quedaba pegado en
    # pantalla para siempre, aunque logicamente la celda ya fuera
    # CELDA_VACIA).
    mv   a0, s1
    mv   a1, s2
    jal  redibujar_celda

    # Centro de la explosion
    mv   a0, s1
    mv   a1, s2
    jal  agregar_explosion_celda

    # 4 direcciones: arriba, abajo, izquierda, derecha
    mv   a0, s1
    mv   a1, s2
    mv   a2, s3
    li   a3, 0
    li   a4, -1
    jal  explotar_direccion

    mv   a0, s1
    mv   a1, s2
    mv   a2, s3
    li   a3, 0
    li   a4, 1
    jal  explotar_direccion

    mv   a0, s1
    mv   a1, s2
    mv   a2, s3
    li   a3, -1
    li   a4, 0
    jal  explotar_direccion

    mv   a0, s1
    mv   a1, s2
    mv   a2, s3
    li   a3, 1
    li   a4, 0
    jal  explotar_direccion

    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: actualizar_bombas
# Recorre la tabla de bombas activas, decrementa cada timer, y
# dispara explotar_bomba cuando un timer llega a 0. Se llama una
# vez por vuelta del loop principal.
# Parametros: ninguno
# Retorno: void
# ================================================================
actualizar_bombas:
    addi sp, sp, -8
    sw   ra, 0(sp)
    sw   s0, 4(sp)   # indice actual

    li   s0, 0

actualizar_bombas_loop:
    li   t0, MAX_BOMBAS
    bge  s0, t0, actualizar_bombas_fin

    la   t0, bomba_activa
    slli t1, s0, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, actualizar_bombas_siguiente   # slot libre, nada que hacer

    la   t0, bomba_timer
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, actualizar_bombas_explotar

    addi t2, t2, -1
    sw   t2, 0(t0)
    j    actualizar_bombas_siguiente

actualizar_bombas_explotar:
    mv   a0, s0
    jal  explotar_bomba
    j    actualizar_bombas_siguiente

actualizar_bombas_siguiente:
    addi s0, s0, 1
    j    actualizar_bombas_loop

actualizar_bombas_fin:
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 8
    ret


# ================================================================
# Funcion: actualizar_explosiones
# Recorre la tabla de explosiones activas, decrementa cada timer,
# y cuando llega a 0 apaga esa celda de fuego (vuelve a
# CELDA_VACIA en el mapa, se libera el slot, y se repinta esa
# celda de negro).
# Parametros: ninguno
# Retorno: void
# ================================================================
actualizar_explosiones:
    addi sp, sp, -16
    sw   ra, 0(sp)
    sw   s0, 4(sp)   # indice actual
    sw   s2, 8(sp)   # columna a apagar (usado solo en actualizar_explosiones_apagar)
    sw   s3, 12(sp)  # fila a apagar

    li   s0, 0

actualizar_explosiones_loop:
    li   t0, MAX_EXPLOSIONES
    bge  s0, t0, actualizar_explosiones_fin

    la   t0, explosion_activa
    slli t1, s0, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, actualizar_explosiones_siguiente

    la   t0, explosion_timer
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, actualizar_explosiones_apagar

    addi t2, t2, -1
    sw   t2, 0(t0)
    j    actualizar_explosiones_siguiente

actualizar_explosiones_apagar:
    # Liberar el slot
    la   t0, explosion_activa
    add  t0, t0, t1
    sw   zero, 0(t0)

    # Leer columna/fila y si esta celda debe revelar la salida
    la   t0, explosion_col
    add  t0, t0, t1
    lw   a0, 0(t0)
    la   t0, explosion_fila
    add  t0, t0, t1
    lw   a1, 0(t0)
    la   t0, explosion_revela_salida
    add  t0, t0, t1
    lw   t6, 0(t0)
    sw   zero, 0(t0)     # resetear el campo para el proximo uso de este slot

    # Guardar en registros callee-saved antes de los jal
    mv   s2, a0
    mv   s3, a1

    mv   a0, s2
    mv   a1, s3
    beqz t6, actualizar_explosiones_tipo_vacia
    li   a2, CELDA_SALIDA
    j    actualizar_explosiones_set_tipo

actualizar_explosiones_tipo_vacia:
    li   a2, CELDA_VACIA

actualizar_explosiones_set_tipo:
    jal  celda_set_tipo

    mv   a0, s2
    mv   a1, s3
    jal  redibujar_celda

    j    actualizar_explosiones_siguiente

actualizar_explosiones_siguiente:
    addi s0, s0, 1
    j    actualizar_explosiones_loop

actualizar_explosiones_fin:
    lw   s3, 12(sp)
    lw   s2, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 16
    ret
