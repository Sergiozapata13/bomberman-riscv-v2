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
.eqv MAPA_COLUMNAS           13    # tiles jugables de ancho (vuelto a 13x13 desde 14x14: el
                                    # area de 14x14 se sintio demasiado grande una vez que el
                                    # HUD ya estaba construido y probado)
.eqv MAPA_FILAS              13    # tiles jugables de alto (idem)

# ----------------------------------------------------------------
# Franja de HUD (Etapa 8): 3 tiles de ancho a la derecha del mapa,
# 3 tiles de alto debajo. Con MAPA_COLUMNAS/FILAS=13 y
# FB_UNIDADES_LADO=64, el mapa ocupa 13*4=52 fb-unidades; quedan
# 64-52=12 fb-unidades (3 tiles) de HUD en cada franja.
# ----------------------------------------------------------------
.eqv HUD_COL_INICIO_FB       52    # fb-unidad x donde empieza la franja lateral derecha
.eqv HUD_FILA_INICIO_FB      52    # fb-unidad y donde empieza la franja inferior
.eqv HUD_ANCHO_TILES          3    # ancho de la franja lateral, en tiles
.eqv COLOR_HUD_FONDO_LATERAL 0x000A2318  # verde muy oscuro, fondo de la franja lateral
.eqv COLOR_HUD_FONDO_INFERIOR 0x002A170A # marron muy oscuro, fondo de la franja inferior

# ----------------------------------------------------------------
# Contenido del HUD lateral: contadores de vidas/rango/bombas como
# cuadraditos (Etapa 8). Cada cuadradito ocupa HUD_CUADRADITO
# fb-unidades de lado; HUD_CUADRADITOS_POR_FILA caben en el ancho
# de la franja lateral (HUD_ANCHO_TILES*TILE_SIZE=8 fb-unidades).
# ----------------------------------------------------------------
.eqv HUD_CUADRADITO             2   # lado de cada cuadradito, en fb-unidades (16px)
.eqv HUD_CUADRADITOS_POR_FILA   4   # cuantos caben por fila en el ancho de la franja lateral
.eqv HUD_MARGEN_IZQ             0   # margen entre el borde de la franja y el primer cuadradito.
                                    # Debe ser 0: HUD_CUADRADITOS_POR_FILA(4) * HUD_CUADRADITO(2)
                                    # = 8 fb-unidades = exactamente el ancho de la franja lateral
                                    # (HUD_ANCHO_TILES*TILE_SIZE=8) -- cualquier margen > 0 hace
                                    # que la ultima columna de cuadraditos se salga del
                                    # framebuffer (bug encontrado y corregido: con margen=1 el
                                    # calculo daba x_max=65, uno mas alla del limite de 64
                                    # fb-unidades del framebuffer).

.eqv HUD_VIDAS_FILA_INICIO_FB   2   # fila (relativa al inicio de la franja) donde arrancan los cuadraditos de vidas
.eqv HUD_RANGO_FILA_INICIO_FB  10   # idem para rango
.eqv HUD_BOMBAS_FILA_INICIO_FB 16   # idem para bombas

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
.eqv BOMBA_TIMER_INICIAL    220    # "ticks" del loop principal antes de explotar. Bajado de
                                   # 400 (que se sentia demasiado largo). NOTA: sigue siendo
                                   # una aproximacion sin medir FPS real -- calibrar jugando,
                                   # igual que FRAME_DELAY_CICLOS.
.eqv EXPLOSION_TIMER_INICIAL 30   # ticks que dura visible cada celda de fuego antes de apagarse
.eqv JUGADOR_RANGO_INICIAL     1  # celdas de alcance de la explosion en cada direccion desde el centro (antes de powerup de llama)
.eqv JUGADOR_MAX_BOMBAS_INICIAL 1  # bombas propias simultaneas permitidas antes de recoger powerup de bomba extra
.eqv JUGADOR_RANGO_TOPE         5  # rango maximo alcanzable con powerups de llama; llamas adicionales no hacen nada
.eqv JUGADOR_MAX_BOMBAS_TOPE    8  # tope de bombas simultaneas con powerups de bomba extra, igual a MAX_BOMBAS (tope fisico de la tabla)

# ----------------------------------------------------------------
# Vidas e invulnerabilidad (Etapa 4)
# ----------------------------------------------------------------
.eqv JUGADOR_VIDAS_INICIAL     3    # vidas iniciales, estandar Bomberman clasico
.eqv JUGADOR_VIDAS_TOPE        9    # tope maximo de vidas acumulables con powerup de vida extra
.eqv JUGADOR_INVULN_FRAMES   800    # "ticks" del loop principal de invulnerabilidad tras
                                    # perder una vida. Subido de 400 a 800 (el doble) para
                                    # dar aun mas margen de reaccion tras perder una vida.
.eqv INVULN_PARPADEO_INTERVALO   8  # cada cuantas vueltas del loop alterna la fase de
                                    # parpadeo del jugador mientras es invulnerable
.eqv SPAWN_COL                  1   # columna de tile del punto de spawn del nivel
.eqv SPAWN_FILA                 1   # fila de tile del punto de spawn del nivel

# ----------------------------------------------------------------
# Enemigos (Etapa 5)
# ----------------------------------------------------------------
.eqv MAX_ENEMIGOS               6    # tope de la tabla, aunque el Nivel 1 solo usa 3

# ----------------------------------------------------------------
# Power-ups visibles en el suelo (Etapa 6)
# ----------------------------------------------------------------
.eqv MAX_POWERUPS_SUELO         8    # power-ups visibles simultaneos (quedan tras destruir bloques)
.eqv ENEMIGO_TIPO_RECTO         0    # sigue recto hasta chocar, luego cambia de direccion
.eqv ENEMIGO_TIPO_ALEATORIO     1    # cambia de direccion al azar en cada tile, ademas de al chocar
.eqv ENEMIGO_TIPO_PERSEGUIDOR   2    # prioriza moverse hacia el jugador
.eqv ENEMIGO_MOVIMIENTO_INTERVALO_FRAMES  35   # los enemigos se mueven una vez cada esta
                                                # cantidad de "unidades de FRAME_DELAY_CICLOS"
                                                # transcurridas, no cada N vueltas fijas del
                                                # loop -- esto ata su velocidad al mismo
                                                # tiempo real aproximado que usa esperar_frame,
                                                # asi que si se recalibra FRAME_DELAY_CICLOS,
                                                # la velocidad relativa jugador/enemigos se
                                                # mantiene consistente en vez de desincronizarse.
.eqv ENEMIGO_VELOCIDAD    TILE_SIZE  # igual que el jugador: saltos de tile completo, sin el
                                     # conflicto de granularidad fraccionaria que ya resolvimos
                                     # para el jugador en la Etapa 2/3

.eqv FRAME_DELAY_CICLOS      5000  # iteraciones del busy-wait de esperar_frame; calibrar a gusto (mas alto = mas lento/estable, mas bajo = mas rapido). Bajado de 300000 tras pasar a redibujado parcial (Etapa 2): con mucho menos trabajo por frame, un delay tan alto se sentia innecesariamente lento.

# ----------------------------------------------------------------
# Colores en formato 0x00RRGGBB
# ----------------------------------------------------------------
.eqv COLOR_NEGRO         0x00000000
.eqv COLOR_BLANCO        0x00FFFFFF
.eqv COLOR_ROJO          0x00FF0000
.eqv COLOR_VERDE         0x0000FF00
.eqv COLOR_AZUL          0x000000FF
.eqv COLOR_LADRILLO      0x00E86F00   # bloque destructible (color plano, ya no se usa tras el sprite con textura, se deja por compatibilidad)
.eqv COLOR_ACERO         0x00B0B0B0   # bloque indestructible (idem)
.eqv COLOR_ACERO_OSCURO    0x00707070   # borde/sombra del sprite de acero
.eqv COLOR_ACERO_CLARO     0x00C8C8C8   # cara superior del sprite de acero
.eqv COLOR_LADRILLO_CLARO  0x00C85A00   # cuerpo del ladrillo en el sprite destructible
.eqv COLOR_MORTERO         0x00703300   # lineas de mortero entre ladrillos
.eqv COLOR_AMARILLO      0x00FFD000   # salida / detalles
.eqv COLOR_JUGADOR       0x0000FFFF   # cian, temporal para checkpoint visual
.eqv COLOR_ENEMIGO_RECTO       0x00FF00A0   # rosa/magenta
.eqv COLOR_ENEMIGO_ALEATORIO   0x00A000FF   # violeta
.eqv COLOR_ENEMIGO_PERSEGUIDOR 0x00804000   # marron
.eqv COLOR_POWERUP_LLAMA       0x00FFEE33   # amarillo claro
.eqv COLOR_POWERUP_BOMBA_EXTRA 0x0033CCFF   # celeste
.eqv COLOR_POWERUP_VIDA_EXTRA  0x0033FF66   # verde -- da una vida extra al recogerlo

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
.eqv POWERUP_VIDA_EXTRA      3   # suma 1 vida al jugador al recogerlo (reemplazo del
                                  # powerup de patin: la velocidad de movimiento fraccionario
                                  # se probo dos veces y ambas genero corrupcion visual del
                                  # sprite -- ver conversacion de diseno -- asi que se
                                  # reemplazo por un efecto que aprovecha el sistema de vidas
                                  # ya construido en la Etapa 4, sin tocar la granularidad de
                                  # movimiento estable)
.eqv POWERUP_SALIDA_OCULTA   4   # revela CELDA_SALIDA al destruir el bloque


.data
# ----------------------------------------------------------------
# Sprites con textura (Etapa de pulido visual): cada tabla tiene
# 16 words en orden fila por fila (fila 0 izq->der, fila 1, etc.)
# representando una grilla de 4x4 fb-unidades (= 1 tile de 32x32px
# reales). pintar_sprite_16 recorre esta tabla y pinta cada
# fb-unidad con su color correspondiente.
# ----------------------------------------------------------------
sprite_indestructible:
    .word COLOR_ACERO_OSCURO, COLOR_ACERO_OSCURO, COLOR_ACERO_OSCURO, COLOR_ACERO_OSCURO
    .word COLOR_ACERO_OSCURO, COLOR_ACERO_CLARO,  COLOR_ACERO_CLARO,  COLOR_ACERO_OSCURO
    .word COLOR_ACERO_OSCURO, COLOR_ACERO_CLARO,  COLOR_ACERO_CLARO,  COLOR_ACERO_OSCURO
    .word COLOR_ACERO_OSCURO, COLOR_ACERO_OSCURO, COLOR_ACERO_OSCURO, COLOR_ACERO_OSCURO

sprite_destructible:
    .word COLOR_MORTERO,        COLOR_LADRILLO_CLARO, COLOR_LADRILLO_CLARO, COLOR_LADRILLO_CLARO
    .word COLOR_LADRILLO_CLARO, COLOR_LADRILLO_CLARO, COLOR_MORTERO,        COLOR_LADRILLO_CLARO
    .word COLOR_MORTERO,        COLOR_LADRILLO_CLARO, COLOR_LADRILLO_CLARO, COLOR_LADRILLO_CLARO
    .word COLOR_LADRILLO_CLARO, COLOR_LADRILLO_CLARO, COLOR_MORTERO,        COLOR_LADRILLO_CLARO


# ----------------------------------------------------------------
# Mapa de los niveles (13x13 celdas, achicado de 16x16 en la
# Etapa 8 para reservar franja de HUD). Cada word empaca:
#   bits [7:0]   = tipo de terreno (VACIA=0, INDESTRUCTIBLE=1,
#                  DESTRUCTIBLE=2, SALIDA=3)
#   bits [15:8]  = power-up oculto bajo el bloque destructible
#                  (NINGUNO=0, LLAMA=1, BOMBA_EXTRA=2, VIDA_EXTRA=3,
#                  SALIDA_OCULTA=4)
#
# Los valores estan pre-calculados como literales (tipo | (pu<<8))
# en vez de usar expresiones dentro de .word, porque RARS no
# garantiza soporte de expresiones aritmeticas en directivas de
# datos (ver github.com/TheThirdOne/rars/issues/217, abierto).
#
# *** Etapa 7: 3 niveles *** mapa_nivel_1/2/3 son los datos FIJOS
# de cada nivel (nunca se modifican en tiempo de ejecucion).
# mapa_nivel (mas abajo) es el array de TRABAJO que toda la logica
# de juego ya existente lee y escribe -- cargar_nivel() copia el
# mapa fijo correspondiente dentro de mapa_nivel al empezar cada
# nivel.
#
# *** Etapa 8: mapa 13x13 (vuelto de 14x14 -- 14x14 se sintio
# demasiado grande una vez que el HUD ya estaba construido y
# probado). Spawn del jugador (1,1); spawn de enemigos
# (11,3),(1,11),(10,11).
# ***
#
# Nivel 1: ~40% destructibles, 74 celdas vacias conectadas
# (verificado por BFS). Power-ups: LLAMA (2,3), BOMBA_EXTRA (5,7),
# VIDA_EXTRA (5,3). Salida oculta en (9,8).
# ----------------------------------------------------------------
mapa_nivel_1:
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1
    .word   1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1
    .word   1,  0,  1,258,  1,  0,  1,  2,  1,  0,  1,  0,  1
    .word   1,  0,  2,  0,  0,  2,  0,  0,  0,  0,  0,  0,  1
    .word   1,  0,  1,  0,  1,  2,  1,  0,  1,  0,  1,  0,  1
    .word   1,  0,  0,770,  2,  0,  0,514,  0,  2,  0,  0,  1
    .word   1,  0,  1,  0,  1,  0,  1,  2,  1,  0,  1,  0,  1
    .word   1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  2,  1
    .word   1,  0,  1,  0,  1,  0,  1,  2,  1,  0,  1,  0,  1
    .word   1,  0,  2,  0,  2,  0,  0,  2,1026,  0,  0,  2,  1
    .word   1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1
    .word   1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1

# Nivel 2: ~50% destructibles, 59 celdas vacias conectadas.
# Power-ups: LLAMA (2,5), BOMBA_EXTRA (5,8), VIDA_EXTRA (7,2).
# Salida oculta en (10,11).
mapa_nivel_2:
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1
    .word   1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1
    .word   1,  0,  1,  2,  1,  0,  1,  0,  1,  0,  1,  0,  1
    .word   1,  0,  2,  2,  2,  0,  0,  2,  0,  0,  0,  0,  1
    .word   1,  0,  1,  0,  1,258,  1,  2,  1,  2,  1,  0,  1
    .word   1,  0,  0,  0,  2,  2,  2,  2,514,  2,  0,  2,  1
    .word   1,  0,  1,  2,  1,  2,  1,  0,  1,  2,  1,  0,  1
    .word   1,  0,770,  2,  2,  0,  0,  0,  0,  0,  0,  2,  1
    .word   1,  0,  1,  2,  1,  0,  1,  0,  1,  0,  1,  0,  1
    .word   1,  0,  0,  0,  0,  0,  0,  2,  0,  0,  0,  0,  1
    .word   1,  0,  1,  2,  1,  2,  1,  0,  1,  0,  1,1026,  1
    .word   1,  0,  2,  0,  0,  0,  0,  2,  2,  0,  0,  0,  1
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1

# Nivel 3: ~60% destructibles (el mas dificil), 44 celdas vacias
# conectadas. Power-ups: LLAMA (2,7), BOMBA_EXTRA (7,3),
# VIDA_EXTRA (5,7). Salida oculta en (9,9).
mapa_nivel_3:
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1
    .word   1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1
    .word   1,  0,  1,  2,  1,  2,  1,258,  1,  2,  1,  0,  1
    .word   1,  0,  2,  2,  2,  2,  2,  2,  2,  0,  0,  0,  1
    .word   1,  0,  1,  2,  1,  2,  1,  0,  1,  0,  1,  2,  1
    .word   1,  0,  2,  2,  2,  0,  2,770,  0,  0,  0,  2,  1
    .word   1,  0,  1,  0,  1,  2,  1,  0,  1,  0,  1,  2,  1
    .word   1,  0,  2,514,  2,  2,  2,  0,  0,  0,  0,  0,  1
    .word   1,  0,  1,  2,  1,  0,  1,  0,  1,  0,  1,  0,  1
    .word   1,  0,  2,  0,  2,  2,  2,  2,  2,1026,  0,  0,  1
    .word   1,  0,  1,  2,  1,  0,  1,  0,  1,  0,  1,  0,  1
    .word   1,  0,  2,  2,  0,  0,  2,  2,  0,  2,  0,  0,  1
    .word   1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1


# ----------------------------------------------------------------
# Array de TRABAJO del mapa: toda la logica de juego existente
# (celda_tipo, celda_set_tipo, celda_es_solida, pintar_mapa, etc.)
# lee y escribe aqui. Se llena copiando el mapa fijo correspondiente
# al nivel actual con cargar_nivel(). El contenido inicial (todo
# INDESTRUCTIBLE, .word 1:169) es irrelevante: siempre se
# sobreescribe completo antes de usarse, en main, antes del primer
# pintar_mapa.
# ----------------------------------------------------------------
mapa_nivel: .word 1:169

nivel_actual: .word 1    # nivel activo: 1, 2, o 3


# ----------------------------------------------------------------
# Posicion del jugador, en fb-unidades absolutas (esquina superior
# izquierda del sprite de 1 tile = TILE_SIZE fb-unidades). Spawn
# inicial: tile (1,1) -> fb-unidad (4,4) porque TILE_SIZE=4.
# ----------------------------------------------------------------
jugador_x: .word 4
jugador_y: .word 4
jugador_rango: .word JUGADOR_RANGO_INICIAL
jugador_max_bombas: .word JUGADOR_MAX_BOMBAS_INICIAL
jugador_bombas_activas: .word 0    # cuantas bombas propias tiene colocadas ahora mismo
jugador_vidas: .word JUGADOR_VIDAS_INICIAL
jugador_invuln: .word 0    # frames restantes de invulnerabilidad; 0 = vulnerable


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
explosion_revela_powerup: .word 0:40  # tipo de power-up a crear en el suelo al apagarse (0 = ninguno)


# ----------------------------------------------------------------
# Tabla de enemigos (arrays paralelos, MAX_ENEMIGOS slots).
# enemigo_activo[i] = 0 significa muerto/inexistente; 1 = vivo.
# enemigo_col/fila: posicion actual en coordenadas de TILE (no
# fb-unidades -- los enemigos, igual que el jugador desde la
# Etapa 3, se mueven en saltos de tile completo).
# enemigo_dir_col/dir_fila: direccion actual de movimiento, como
# delta de tile (-1, 0, o 1 en cada eje, nunca ambos distintos de
# 0 a la vez).
# ----------------------------------------------------------------
enemigo_activo:   .word 0:6   # MAX_ENEMIGOS
enemigo_tipo:     .word 0:6
enemigo_col:      .word 0:6
enemigo_fila:     .word 0:6
enemigo_dir_col:  .word 0:6
enemigo_dir_fila: .word 0:6

# Contador de vueltas del loop principal, para saber cuando le
# toca moverse a los enemigos (cada ENEMIGO_MOVIMIENTO_INTERVALO_FRAMES).
contador_vueltas: .word 0

# ----------------------------------------------------------------
# Tabla de power-ups visibles en el suelo (arrays paralelos,
# MAX_POWERUPS_SUELO slots). Aparecen al destruir un bloque que
# tenia uno oculto, y se recolectan cuando el jugador camina sobre
# su celda.
# ----------------------------------------------------------------
powerup_suelo_activo: .word 0:8   # MAX_POWERUPS_SUELO
powerup_suelo_tipo:   .word 0:8
powerup_suelo_col:    .word 0:8
powerup_suelo_fila:   .word 0:8


.text
main:
    jal  limpiar_pantalla
    jal  pintar_fondo_hud
    jal  cargar_nivel
    jal  pintar_mapa
    jal  pintar_hud_completo

    # Dibujar al jugador en su posicion inicial de spawn (fuera del
    # loop, se pinta una sola vez aqui; despues solo se redibuja
    # si realmente se mueve, ver loop_principal).
    lw   a0, jugador_x
    lw   a1, jugador_y
    li   a2, COLOR_JUGADOR
    li   a3, TILE_SIZE
    li   a4, TILE_SIZE
    jal  pintar_bloque_fb

    jal  spawn_enemigos_del_nivel

loop_principal:
    # --- Actualizaciones que corren TODOS los frames, con o sin
    #     tecla presionada (los timers avanzan con el tiempo) ---
    jal  actualizar_bombas
    jal  actualizar_explosiones
    jal  actualizar_enemigos

    # Incrementar el contador de vueltas (usado por
    # actualizar_enemigos para saber cuando moverse)
    lw   t0, contador_vueltas
    addi t0, t0, 1
    la   t1, contador_vueltas
    sw   t0, 0(t1)

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
    # --- Resolver colisiones entre entidades. Se ubica aqui,
    #     despues de que el jugador ya se movio, los enemigos ya
    #     se movieron, y las bombas/explosiones ya se actualizaron
    #     este frame, para que el chequeo vea el estado final y
    #     consistente del frame. ---

    jal  recolectar_powerups

    # Explosion vs enemigos: corre siempre, la invulnerabilidad es
    # solo del jugador, no protege a los enemigos.
    jal  matar_enemigos_en_fuego

    # Jugador vs salida: se chequea SIEMPRE, incluso si el jugador
    # es invulnerable (avanzar de nivel no es una amenaza de la
    # que haya que protegerse, asi que no debe bloquearse por eso).
    jal  jugador_toco_salida
    beqz a0, loop_principal_colisiones_no_salida

    jal  nivel_limpio
    beqz a0, loop_principal_colisiones_no_salida   # quedan enemigos vivos: la salida no funciona todavia

    jal  avanzar_nivel
    j    loop_principal_fin_de_vuelta

loop_principal_colisiones_no_salida:
    jal  actualizar_invulnerabilidad

    lw   t0, jugador_invuln
    beqz t0, loop_principal_colisiones_vulnerable

    jal  parpadear_jugador
    j    loop_principal_fin_de_vuelta   # invulnerable: no puede perder vida este frame

loop_principal_colisiones_vulnerable:
    # Jugador vs fuego O jugador vs enemigo: cualquiera de los dos
    # le cuesta una vida.
    jal  jugador_toco_explosion
    bnez a0, loop_principal_perder_vida

    jal  jugador_toco_enemigo
    beqz a0, loop_principal_fin_de_vuelta

loop_principal_perder_vida:
    jal  perder_vida

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
# Funcion: pintar_fondo_hud
# Pinta el fondo de las dos franjas de HUD (lateral derecha e
# inferior) con sus colores distintivos. Se llama una vez al
# inicio de cada nivel (main/avanzar_nivel), antes de pintar el
# contenido real del HUD encima.
# Parametros: ninguno
# Retorno: void
# ================================================================
pintar_fondo_hud:
    addi sp, sp, -4
    sw   ra, 0(sp)

    # Franja lateral derecha: desde (HUD_COL_INICIO_FB, 0) hasta
    # el borde de la pantalla (FB_UNIDADES_LADO), por toda la
    # altura de la pantalla (incluye la esquina inferior derecha).
    li   a0, HUD_COL_INICIO_FB
    li   a1, 0
    li   a2, COLOR_HUD_FONDO_LATERAL
    li   a3, HUD_ANCHO_TILES
    slli a3, a3, TILE_SHIFT       # ancho en tiles -> fb-unidades
    li   a4, FB_UNIDADES_LADO
    jal  pintar_bloque_fb

    # Franja inferior: desde (0, HUD_FILA_INICIO_FB) hasta el
    # borde derecho del AREA DE MAPA solamente (no se solapa con
    # la franja lateral, que ya cubrio esa esquina arriba).
    li   a0, 0
    li   a1, HUD_FILA_INICIO_FB
    li   a2, COLOR_HUD_FONDO_INFERIOR
    li   a3, HUD_COL_INICIO_FB     # ancho: justo hasta donde empieza la franja lateral
    li   a4, HUD_ANCHO_TILES
    slli a4, a4, TILE_SHIFT
    jal  pintar_bloque_fb

    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: pintar_contador_hud
# Dibuja "cantidad" cuadraditos de HUD_CUADRADITO fb-unidades de
# lado, en filas de HUD_CUADRADITOS_POR_FILA, empezando en
# (HUD_COL_INICIO_FB + HUD_MARGEN_IZQ, fila_inicio_fb) dentro de
# la franja lateral. Antes de dibujar, borra el area completa que
# podria haber ocupado el maximo posible de esa categoria (con
# COLOR_HUD_FONDO_LATERAL), para que bajar el conteo (por ejemplo
# perder una vida) borre correctamente los cuadraditos sobrantes
# en vez de dejarlos pegados.
# Parametros:
#   a0: cantidad de cuadraditos a mostrar
#   a1: fila de inicio (fb-unidad, relativa al inicio de pantalla)
#   a2: color de los cuadraditos
#   a3: maximo posible de esta categoria (para saber cuanto borrar)
# Retorno: void
# ================================================================
pintar_contador_hud:
    addi sp, sp, -24
    sw   ra, 0(sp)
    sw   s0, 4(sp)    # cantidad a mostrar
    sw   s1, 8(sp)    # fila de inicio
    sw   s2, 12(sp)   # color
    sw   s3, 16(sp)   # maximo (para calcular cuanto borrar)
    sw   s4, 20(sp)   # indice de cuadradito actual (0-based)

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2
    mv   s3, a3

    # Borrar el area completa reservada para el maximo de esta
    # categoria (todas las filas que el maximo podria necesitar),
    # antes de dibujar los cuadraditos reales.
    addi t0, s3, HUD_CUADRADITOS_POR_FILA
    addi t0, t0, -1
    li   t1, HUD_CUADRADITOS_POR_FILA
    div  t0, t0, t1          # filas necesarias para el MAXIMO de esta categoria
    li   t1, HUD_CUADRADITO
    mul  t0, t0, t1          # alto en fb-unidades a borrar

    li   a0, HUD_COL_INICIO_FB
    addi a0, a0, HUD_MARGEN_IZQ
    mv   a1, s1
    li   a2, COLOR_HUD_FONDO_LATERAL
    li   a3, HUD_CUADRADITOS_POR_FILA
    li   t1, HUD_CUADRADITO
    mul  a3, a3, t1
    mv   a4, t0
    jal  pintar_bloque_fb

    li   s4, 0

pintar_contador_hud_loop:
    bge  s4, s0, pintar_contador_hud_fin

    li   t0, HUD_CUADRADITOS_POR_FILA
    rem  t1, s4, t0          # columna dentro de la fila (0..POR_FILA-1)
    div  t2, s4, t0          # numero de fila (0-based)

    li   t3, HUD_CUADRADITO
    mul  t1, t1, t3          # offset x del cuadradito, en fb-unidades
    li   a0, HUD_COL_INICIO_FB
    addi a0, a0, HUD_MARGEN_IZQ
    add  a0, a0, t1

    mul  t2, t2, t3          # offset y del cuadradito
    add  a1, s1, t2

    mv   a2, s2
    li   a3, HUD_CUADRADITO
    li   a4, HUD_CUADRADITO
    jal  pintar_bloque_fb

    addi s4, s4, 1
    j    pintar_contador_hud_loop

pintar_contador_hud_fin:
    lw   s4, 20(sp)
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 24
    ret


# ================================================================
# Funcion: pintar_hud_completo
# Redibuja las 3 categorias del HUD lateral (vidas, rango, bombas)
# con los valores actuales del jugador. Se llama cada vez que
# alguno de esos valores puede haber cambiado (perder/ganar vida,
# recoger powerup de rango o bomba extra).
# Parametros: ninguno (lee jugador_vidas/jugador_rango/jugador_max_bombas)
# Retorno: void
# ================================================================
pintar_hud_completo:
    addi sp, sp, -4
    sw   ra, 0(sp)

    lw   a0, jugador_vidas
    li   a1, HUD_VIDAS_FILA_INICIO_FB
    li   a2, COLOR_POWERUP_VIDA_EXTRA
    li   a3, JUGADOR_VIDAS_TOPE
    jal  pintar_contador_hud

    lw   a0, jugador_rango
    li   a1, HUD_RANGO_FILA_INICIO_FB
    li   a2, COLOR_POWERUP_LLAMA
    li   a3, JUGADOR_RANGO_TOPE
    jal  pintar_contador_hud

    lw   a0, jugador_max_bombas
    li   a1, HUD_BOMBAS_FILA_INICIO_FB
    li   a2, COLOR_POWERUP_BOMBA_EXTRA
    li   a3, JUGADOR_MAX_BOMBAS_TOPE
    jal  pintar_contador_hud

    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: esperar_frame
# Busy-wait simple para regular la velocidad del game loop.
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
    mv   s6, s3

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

    slli a0, a0, TILE_SHIFT
    slli a1, a1, TILE_SHIFT
    slli a3, a3, TILE_SHIFT
    slli a4, a4, TILE_SHIFT
    jal  pintar_bloque_fb

    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: pintar_sprite_16
# Pinta un sprite con textura de 4x4 fb-unidades (= 1 tile de
# 32x32px reales) en la celda de tile dada, leyendo los 16 colores
# de una tabla en memoria (fila por fila, igual orden que
# sprite_indestructible/sprite_destructible).
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
#   a2: direccion de la tabla de 16 words (colores)
# Retorno: void
# ================================================================
pintar_sprite_16:
    addi sp, sp, -28
    sw   ra, 0(sp)
    sw   s0, 4(sp)    # x base del tile, en fb-unidades
    sw   s1, 8(sp)    # y base del tile, en fb-unidades
    sw   s2, 12(sp)   # direccion de la tabla (avanza 4 bytes por color leido)
    sw   s3, 16(sp)   # fila actual dentro del sprite (0..3)
    sw   s4, 20(sp)   # columna actual dentro del sprite (0..3)
    sw   s5, 24(sp)   # color leido de la tabla

    slli s0, a0, TILE_SHIFT
    slli s1, a1, TILE_SHIFT
    mv   s2, a2
    li   s3, 0

pintar_sprite_16_fila:
    li   t0, 4
    bge  s3, t0, pintar_sprite_16_fin

    li   s4, 0

pintar_sprite_16_col:
    li   t0, 4
    bge  s4, t0, pintar_sprite_16_col_fin

    lw   s5, 0(s2)

    add  a0, s0, s4
    add  a1, s1, s3
    mv   a2, s5
    jal  pintar_unidad

    addi s2, s2, 4
    addi s4, s4, 1
    j    pintar_sprite_16_col

pintar_sprite_16_col_fin:
    addi s3, s3, 1
    j    pintar_sprite_16_fila

pintar_sprite_16_fin:
    lw   s5, 24(sp)
    lw   s4, 20(sp)
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 28
    ret


# ================================================================
# Funcion: celda_color
# Parametros:
#   a0: word de celda completa (tipo + power-up empacados)
# Retorno:
#   a0: color (0x00RRGGBB)
# ================================================================
celda_color:
    andi t0, a0, 0xFF

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
# Funcion: enemigo_en_celda
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno:
#   a0: 1 si hay un enemigo ahi, 0 si no
#   a1: tipo del enemigo encontrado (valido solo si a0=1)
# ================================================================
enemigo_en_celda:
    addi sp, sp, -12
    sw   s0, 0(sp)
    sw   s1, 4(sp)
    sw   s2, 8(sp)

    mv   s0, a0
    mv   s1, a1
    li   s2, 0

enemigo_en_celda_loop:
    li   t0, MAX_ENEMIGOS
    bge  s2, t0, enemigo_en_celda_no

    la   t0, enemigo_activo
    slli t1, s2, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, enemigo_en_celda_siguiente

    la   t0, enemigo_col
    add  t0, t0, t1
    lw   t2, 0(t0)
    bne  t2, s0, enemigo_en_celda_siguiente

    la   t0, enemigo_fila
    add  t0, t0, t1
    lw   t2, 0(t0)
    bne  t2, s1, enemigo_en_celda_siguiente

    la   t0, enemigo_tipo
    add  t0, t0, t1
    lw   a1, 0(t0)
    li   a0, 1
    j    enemigo_en_celda_fin

enemigo_en_celda_siguiente:
    addi s2, s2, 1
    j    enemigo_en_celda_loop

enemigo_en_celda_no:
    li   a0, 0
    li   a1, 0

enemigo_en_celda_fin:
    lw   s2, 8(sp)
    lw   s1, 4(sp)
    lw   s0, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: color_de_enemigo
# Parametros:
#   a0: tipo de enemigo
# Retorno:
#   a0: color
# ================================================================
color_de_enemigo:
    li   t0, ENEMIGO_TIPO_RECTO
    beq  a0, t0, color_de_enemigo_recto
    li   t0, ENEMIGO_TIPO_ALEATORIO
    beq  a0, t0, color_de_enemigo_aleatorio

    li   a0, COLOR_ENEMIGO_PERSEGUIDOR
    ret

color_de_enemigo_recto:
    li   a0, COLOR_ENEMIGO_RECTO
    ret

color_de_enemigo_aleatorio:
    li   a0, COLOR_ENEMIGO_ALEATORIO
    ret


# ================================================================
# Funcion: powerup_suelo_en_celda
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno:
#   a0: 1 si hay un power-up ahi, 0 si no
#   a1: tipo del power-up encontrado (valido solo si a0=1)
# ================================================================
powerup_suelo_en_celda:
    addi sp, sp, -12
    sw   s0, 0(sp)
    sw   s1, 4(sp)
    sw   s2, 8(sp)

    mv   s0, a0
    mv   s1, a1
    li   s2, 0

powerup_suelo_en_celda_loop:
    li   t0, MAX_POWERUPS_SUELO
    bge  s2, t0, powerup_suelo_en_celda_no

    la   t0, powerup_suelo_activo
    slli t1, s2, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, powerup_suelo_en_celda_siguiente

    la   t0, powerup_suelo_col
    add  t0, t0, t1
    lw   t2, 0(t0)
    bne  t2, s0, powerup_suelo_en_celda_siguiente

    la   t0, powerup_suelo_fila
    add  t0, t0, t1
    lw   t2, 0(t0)
    bne  t2, s1, powerup_suelo_en_celda_siguiente

    la   t0, powerup_suelo_tipo
    add  t0, t0, t1
    lw   a1, 0(t0)
    li   a0, 1
    j    powerup_suelo_en_celda_fin

powerup_suelo_en_celda_siguiente:
    addi s2, s2, 1
    j    powerup_suelo_en_celda_loop

powerup_suelo_en_celda_no:
    li   a0, 0
    li   a1, 0

powerup_suelo_en_celda_fin:
    lw   s2, 8(sp)
    lw   s1, 4(sp)
    lw   s0, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: color_de_powerup_suelo
# Parametros:
#   a0: tipo de power-up (POWERUP_LLAMA, POWERUP_BOMBA_EXTRA, POWERUP_VIDA_EXTRA)
# Retorno:
#   a0: color
# ================================================================
color_de_powerup_suelo:
    li   t0, POWERUP_LLAMA
    beq  a0, t0, color_de_powerup_suelo_llama
    li   t0, POWERUP_BOMBA_EXTRA
    beq  a0, t0, color_de_powerup_suelo_bomba

    li   a0, COLOR_POWERUP_VIDA_EXTRA
    ret

color_de_powerup_suelo_llama:
    li   a0, COLOR_POWERUP_LLAMA
    ret

color_de_powerup_suelo_bomba:
    li   a0, COLOR_POWERUP_BOMBA_EXTRA
    ret


# ================================================================
# Funcion: redibujar_celda
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void
# ================================================================
redibujar_celda:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)

    mv   s0, a0
    mv   s1, a1

    mv   a0, s0
    mv   a1, s1
    jal  jugador_esta_en_celda
    bnez a0, redibujar_celda_jugador

    mv   a0, s0
    mv   a1, s1
    jal  enemigo_en_celda
    bnez a0, redibujar_celda_enemigo

    mv   a0, s0
    mv   a1, s1
    jal  powerup_suelo_en_celda
    bnez a0, redibujar_celda_powerup

    mv   a0, s0
    mv   a1, s1
    jal  celda_tipo

    li   t0, CELDA_INDESTRUCTIBLE
    beq  a0, t0, redibujar_celda_sprite_indestructible
    li   t0, CELDA_DESTRUCTIBLE
    beq  a0, t0, redibujar_celda_sprite_destructible

    jal  celda_color
    j    redibujar_celda_pintar

redibujar_celda_sprite_indestructible:
    la   a2, sprite_indestructible
    mv   a0, s0
    mv   a1, s1
    jal  pintar_sprite_16
    j    redibujar_celda_fin

redibujar_celda_sprite_destructible:
    la   a2, sprite_destructible
    mv   a0, s0
    mv   a1, s1
    jal  pintar_sprite_16
    j    redibujar_celda_fin

redibujar_celda_jugador:
    li   a0, COLOR_JUGADOR
    j    redibujar_celda_pintar

redibujar_celda_enemigo:
    mv   a0, a1
    jal  color_de_enemigo
    j    redibujar_celda_pintar

redibujar_celda_powerup:
    mv   a0, a1
    jal  color_de_powerup_suelo

redibujar_celda_pintar:
    mv   a2, a0
    mv   a0, s0
    mv   a1, s1
    li   a3, 1
    li   a4, 1
    jal  pintar_bloque_tiles

redibujar_celda_fin:
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: cargar_nivel
# Copia el mapa fijo correspondiente a nivel_actual (1, 2, o 3)
# dentro del array de trabajo mapa_nivel, y limpia las tablas de
# entidades transitorias del nivel anterior (bombas, explosiones,
# power-ups en el suelo, enemigos) -- estas SIEMPRE se reinician
# entre niveles, a diferencia del estado del jugador (vidas,
# rango, max_bombas), que segun diseno persiste entre niveles y
# esta funcion NO toca.
# Parametros: ninguno (lee nivel_actual)
# Retorno: void
# ================================================================
cargar_nivel:
    addi sp, sp, -8
    sw   ra, 0(sp)
    sw   s0, 4(sp)   # direccion del mapa fijo a copiar

    lw   t0, nivel_actual
    li   t1, 1
    beq  t0, t1, cargar_nivel_uno
    li   t1, 2
    beq  t0, t1, cargar_nivel_dos

    la   s0, mapa_nivel_3
    j    cargar_nivel_copiar

cargar_nivel_uno:
    la   s0, mapa_nivel_1
    j    cargar_nivel_copiar

cargar_nivel_dos:
    la   s0, mapa_nivel_2

cargar_nivel_copiar:
    la   t0, mapa_nivel
    li   t1, MAPA_FILAS
    li   t2, MAPA_COLUMNAS
    mul  t1, t1, t2        # total de celdas = MAPA_FILAS * MAPA_COLUMNAS

cargar_nivel_copiar_loop:
    beqz t1, cargar_nivel_limpiar_entidades

    lw   t2, 0(s0)
    sw   t2, 0(t0)
    addi s0, s0, 4
    addi t0, t0, 4
    addi t1, t1, -1
    j    cargar_nivel_copiar_loop

cargar_nivel_limpiar_entidades:
    # Bombas
    la   t0, bomba_activa
    li   t1, MAX_BOMBAS
cargar_nivel_limpiar_bombas:
    beqz t1, cargar_nivel_limpiar_explosiones
    sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -1
    j    cargar_nivel_limpiar_bombas

cargar_nivel_limpiar_explosiones:
    la   t0, explosion_activa
    li   t1, MAX_EXPLOSIONES
cargar_nivel_limpiar_explosiones_loop:
    beqz t1, cargar_nivel_limpiar_powerups
    sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -1
    j    cargar_nivel_limpiar_explosiones_loop

cargar_nivel_limpiar_powerups:
    la   t0, powerup_suelo_activo
    li   t1, MAX_POWERUPS_SUELO
cargar_nivel_limpiar_powerups_loop:
    beqz t1, cargar_nivel_limpiar_enemigos
    sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -1
    j    cargar_nivel_limpiar_powerups_loop

cargar_nivel_limpiar_enemigos:
    la   t0, enemigo_activo
    li   t1, MAX_ENEMIGOS
cargar_nivel_limpiar_enemigos_loop:
    beqz t1, cargar_nivel_reset_jugador_bombas
    sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -1
    j    cargar_nivel_limpiar_enemigos_loop

cargar_nivel_reset_jugador_bombas:
    # jugador_bombas_activas debe volver a 0: las bombas del nivel
    # anterior ya no existen (se acaban de borrar arriba), asi que
    # el contador de "bombas propias colocadas ahora mismo" tiene
    # que reflejarlo, aunque jugador_max_bombas (el LIMITE, que si
    # persiste como powerup acumulado) no se toca.
    la   t0, jugador_bombas_activas
    sw   zero, 0(t0)

    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 8
    ret


# ================================================================
# Funcion: pintar_mapa
# Parametros: ninguno
# Retorno: void
# ================================================================
pintar_mapa:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)   # fila actual
    sw   s1, 8(sp)   # columna actual

    li   s0, 0

pintar_mapa_fila:
    li   t0, MAPA_FILAS
    bge  s0, t0, pintar_mapa_fin

    li   s1, 0

pintar_mapa_col:
    li   t0, MAPA_COLUMNAS
    bge  s1, t0, pintar_mapa_col_fin

    # Reutiliza redibujar_celda (que ya sabe elegir sprite con
    # textura para INDESTRUCTIBLE/DESTRUCTIBLE, o color plano para
    # el resto) en vez de duplicar esa logica aqui. Al pintar el
    # mapa inicial no hay jugador/enemigo/power-up en ninguna celda
    # todavia, asi que siempre cae en la rama de terreno.
    mv   a0, s1
    mv   a1, s0
    jal  redibujar_celda

    addi s1, s1, 1
    j    pintar_mapa_col

pintar_mapa_col_fin:
    addi s0, s0, 1
    j    pintar_mapa_fila

pintar_mapa_fin:
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: celda_es_solida
# Parametros:
#   a0: columna de tile (puede ser negativa o >=16)
#   a1: fila de tile (puede ser negativa o >=16)
# Retorno:
#   a0: 1 si solida (bloquea), 0 si libre
# ================================================================
celda_es_solida:
    blt   a0, zero, celda_es_solida_si
    li    t2, MAPA_COLUMNAS
    bge   a0, t2, celda_es_solida_si
    blt   a1, zero, celda_es_solida_si
    li    t2, MAPA_FILAS
    bge   a1, t2, celda_es_solida_si

    li    t0, MAPA_COLUMNAS
    mul   t0, a1, t0
    add   t0, t0, a0
    slli  t0, t0, 2
    la    t1, mapa_nivel
    add   t1, t1, t0
    lw    t1, 0(t1)
    andi  t1, t1, 0xFF

    li    t2, CELDA_INDESTRUCTIBLE
    beq   t1, t2, celda_es_solida_si
    li    t2, CELDA_DESTRUCTIBLE
    beq   t1, t2, celda_es_solida_si
    li    t2, CELDA_BOMBA
    beq   t1, t2, celda_es_solida_si

    li    a0, 0
    ret

celda_es_solida_si:
    li    a0, 1
    ret


# ================================================================
# Funcion: hay_colision_mapa
# Parametros:
#   a0: x propuesto del sprite (esquina superior izq, fb-unidades)
#   a1: y propuesto del sprite (esquina superior izq, fb-unidades)
# Retorno:
#   a0: 1 si hay colision (solido), 0 si libre
# ================================================================
hay_colision_mapa:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

    addi s0, a0, HITBOX_MARGEN
    addi s1, a1, HITBOX_MARGEN
    addi s2, s0, HITBOX_SIZE
    addi s2, s2, -1
    addi s3, s1, HITBOX_SIZE
    addi s3, s3, -1

    srai a0, s0, TILE_SHIFT
    srai a1, s1, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

    srai a0, s2, TILE_SHIFT
    srai a1, s1, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

    srai a0, s0, TILE_SHIFT
    srai a1, s3, TILE_SHIFT
    jal  celda_es_solida
    bnez a0, hay_colision_mapa_si

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
# Parametros: ninguno (lee jugador_x/jugador_y y KEY_INPUT_ADDRESS)
# Retorno:
#   a0: 1 si el jugador efectivamente se movio, 0 si no
#   a1: delta x aplicado
#   a2: delta y aplicado
# ================================================================
mover_jugador:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

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
    j    mover_jugador_fin

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
    bnez a0, mover_jugador_bloqueado

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
# Parametros:
#   a0: direccion base del array de activos
#   a1: tamano del array (cantidad de slots)
# Retorno:
#   a0: indice del primer slot libre, o -1 si no hay ninguno
# ================================================================
buscar_slot_libre:
    mv   t0, a0
    li   t1, 0

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
# Parametros: ninguno (lee jugador_x/y y jugador_rango)
# Retorno: void
# ================================================================
colocar_bomba:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

    lw   t0, jugador_x
    srai s1, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai s2, t0, TILE_SHIFT
    lw   s3, jugador_rango

    mv   a0, s1
    mv   a1, s2
    jal  celda_tipo
    li   t1, CELDA_VACIA
    bne  a0, t1, colocar_bomba_fin

    lw   t0, jugador_bombas_activas
    lw   t1, jugador_max_bombas
    bge  t0, t1, colocar_bomba_fin

    la   a0, bomba_activa
    li   a1, MAX_BOMBAS
    jal  buscar_slot_libre
    mv   s0, a0
    blt  s0, zero, colocar_bomba_fin

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

    lw   t2, jugador_bombas_activas
    addi t2, t2, 1
    la   t0, jugador_bombas_activas
    sw   t2, 0(t0)

    mv   a0, s1
    mv   a1, s2
    li   a2, CELDA_BOMBA
    jal  celda_set_tipo

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
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno:
#   a0: tipo de celda (bits bajos de la word, 0-255)
# ================================================================
celda_tipo:
    li   t0, MAPA_COLUMNAS
    mul  t0, a1, t0
    add  t0, t0, a0
    slli t0, t0, 2
    la   t1, mapa_nivel
    add  t1, t1, t0
    lw   t1, 0(t1)
    andi a0, t1, 0xFF
    ret


# ================================================================
# Funcion: celda_powerup_oculto
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno:
#   a0: power-up oculto (0-255)
# ================================================================
celda_powerup_oculto:
    li   t0, MAPA_COLUMNAS
    mul  t0, a1, t0
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
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
#   a2: nuevo tipo de celda (0-255)
# Retorno: void
# ================================================================
celda_set_tipo:
    li   t0, MAPA_COLUMNAS
    mul  t0, a1, t0
    add  t0, t0, a0
    slli t0, t0, 2
    la   t1, mapa_nivel
    add  t1, t1, t0

    lw   t2, 0(t1)
    li   t3, 0xFFFFFF00
    and  t2, t2, t3
    or   t2, t2, a2
    sw   t2, 0(t1)
    ret


# ================================================================
# Funcion: agregar_explosion_celda
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void
# ================================================================
agregar_explosion_celda:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

    mv   s1, a0
    mv   s2, a1

    la   a0, explosion_activa
    li   a1, MAX_EXPLOSIONES
    jal  buscar_slot_libre
    mv   s0, a0
    blt  s0, zero, agregar_explosion_celda_fin

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
    sw   zero, 0(t0)

    la   t0, explosion_revela_powerup
    add  t0, t0, t1
    sw   zero, 0(t0)

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
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void
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
# Funcion: marcar_explosion_revela_powerup
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
#   a2: tipo de power-up (POWERUP_LLAMA, POWERUP_BOMBA_EXTRA, o POWERUP_VIDA_EXTRA)
# Retorno: void
# ================================================================
marcar_explosion_revela_powerup:
    la   t0, explosion_activa
    li   t1, 0

marcar_explosion_revela_powerup_buscar:
    li   t2, MAX_EXPLOSIONES
    bge  t1, t2, marcar_explosion_revela_powerup_fin

    slli t3, t1, 2
    add  t4, t0, t3
    lw   t5, 0(t4)
    beqz t5, marcar_explosion_revela_powerup_siguiente

    la   t4, explosion_col
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, a0, marcar_explosion_revela_powerup_siguiente

    la   t4, explosion_fila
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, a1, marcar_explosion_revela_powerup_siguiente

    la   t4, explosion_revela_powerup
    add  t4, t4, t3
    sw   a2, 0(t4)
    ret

marcar_explosion_revela_powerup_siguiente:
    addi t1, t1, 1
    j    marcar_explosion_revela_powerup_buscar

marcar_explosion_revela_powerup_fin:
    ret


# ================================================================
# Funcion: explotar_direccion
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
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)
    sw   s4, 20(sp)
    sw   s5, 24(sp)

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2
    mv   s3, a3
    mv   s4, a4

explotar_direccion_loop:
    blez s2, explotar_direccion_fin

    add  s0, s0, s3
    add  s1, s1, s4

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
    beq  s5, t0, explotar_direccion_fin

    li   t0, CELDA_SALIDA
    beq  s5, t0, explotar_direccion_fin

    mv   a0, s0
    mv   a1, s1
    jal  agregar_explosion_celda

    li   t0, CELDA_DESTRUCTIBLE
    beq  s5, t0, explotar_direccion_destruir

    li   t0, CELDA_BOMBA
    beq  s5, t0, explotar_direccion_cadena

    addi s2, s2, -1
    j    explotar_direccion_loop

explotar_direccion_destruir:
    mv   a0, s0
    mv   a1, s1
    jal  celda_powerup_oculto
    mv   t6, a0

    li   t0, POWERUP_SALIDA_OCULTA
    beq  t6, t0, explotar_direccion_marcar_salida

    li   t0, POWERUP_NINGUNO
    beq  t6, t0, explotar_direccion_fin

    mv   a0, s0
    mv   a1, s1
    mv   a2, t6
    jal  marcar_explosion_revela_powerup
    j    explotar_direccion_fin

explotar_direccion_marcar_salida:
    mv   a0, s0
    mv   a1, s1
    jal  marcar_explosion_revela_salida

    j    explotar_direccion_fin

explotar_direccion_cadena:
    la   t0, bomba_activa
    li   t1, 0

explotar_direccion_cadena_buscar:
    li   t2, MAX_BOMBAS
    bge  t1, t2, explotar_direccion_fin

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

    la   t4, bomba_timer
    add  t4, t4, t3
    sw   zero, 0(t4)
    j    explotar_direccion_fin

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
# Parametros:
#   a0: indice de la bomba en la tabla (0..MAX_BOMBAS-1)
# Retorno: void
# ================================================================
explotar_bomba:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

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

    la   t0, bomba_activa
    add  t0, t0, t1
    sw   zero, 0(t0)

    lw   t2, jugador_bombas_activas
    addi t2, t2, -1
    la   t0, jugador_bombas_activas
    sw   t2, 0(t0)

    mv   a0, s1
    mv   a1, s2
    li   a2, CELDA_VACIA
    jal  celda_set_tipo

    mv   a0, s1
    mv   a1, s2
    jal  redibujar_celda

    mv   a0, s1
    mv   a1, s2
    jal  agregar_explosion_celda

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
# Parametros: ninguno
# Retorno: void
# ================================================================
actualizar_bombas:
    addi sp, sp, -8
    sw   ra, 0(sp)
    sw   s0, 4(sp)

    li   s0, 0

actualizar_bombas_loop:
    li   t0, MAX_BOMBAS
    bge  s0, t0, actualizar_bombas_fin

    la   t0, bomba_activa
    slli t1, s0, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, actualizar_bombas_siguiente

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
# Parametros: ninguno
# Retorno: void
# ================================================================
actualizar_explosiones:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s2, 8(sp)
    sw   s3, 12(sp)
    sw   s4, 16(sp)

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
    la   t0, explosion_activa
    add  t0, t0, t1
    sw   zero, 0(t0)

    la   t0, explosion_col
    add  t0, t0, t1
    lw   a0, 0(t0)
    la   t0, explosion_fila
    add  t0, t0, t1
    lw   a1, 0(t0)
    la   t0, explosion_revela_salida
    add  t0, t0, t1
    lw   t6, 0(t0)
    sw   zero, 0(t0)

    la   t0, explosion_revela_powerup
    add  t0, t0, t1
    lw   s4, 0(t0)
    sw   zero, 0(t0)

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

    beqz s4, actualizar_explosiones_sin_powerup

    mv   a0, s2
    mv   a1, s3
    mv   a2, s4
    jal  crear_powerup_suelo
    j    actualizar_explosiones_redibujar

actualizar_explosiones_sin_powerup:
    mv   a0, s2
    mv   a1, s3
    jal  redibujar_celda

actualizar_explosiones_redibujar:
    j    actualizar_explosiones_siguiente

actualizar_explosiones_siguiente:
    addi s0, s0, 1
    j    actualizar_explosiones_loop

actualizar_explosiones_fin:
    lw   s4, 16(sp)
    lw   s3, 12(sp)
    lw   s2, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: actualizar_invulnerabilidad
# Parametros: ninguno
# Retorno: void
# ================================================================
actualizar_invulnerabilidad:
    lw   t0, jugador_invuln
    beqz t0, actualizar_invulnerabilidad_fin
    addi t0, t0, -1
    la   t1, jugador_invuln
    sw   t0, 0(t1)

actualizar_invulnerabilidad_fin:
    ret


# ================================================================
# Funcion: jugador_toco_explosion
# Parametros: ninguno (lee jugador_x/jugador_y)
# Retorno:
#   a0: 1 si la celda del jugador es CELDA_EXPLOSION, 0 si no
# ================================================================
jugador_toco_explosion:
    lw   t0, jugador_x
    srai a0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai a1, t0, TILE_SHIFT

    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  celda_tipo
    lw   ra, 0(sp)
    addi sp, sp, 4

    li   t0, CELDA_EXPLOSION
    beq  a0, t0, jugador_toco_explosion_si

    li   a0, 0
    ret

jugador_toco_explosion_si:
    li   a0, 1
    ret


# ================================================================
# Funcion: jugador_toco_salida
# Verifica si la celda de tile donde esta parado el jugador
# actualmente es CELDA_SALIDA (la salida ya revelada del nivel).
# Parametros: ninguno (lee jugador_x/jugador_y)
# Retorno:
#   a0: 1 si la celda del jugador es CELDA_SALIDA, 0 si no
# ================================================================
jugador_toco_salida:
    lw   t0, jugador_x
    srai a0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai a1, t0, TILE_SHIFT

    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  celda_tipo
    lw   ra, 0(sp)
    addi sp, sp, 4

    li   t0, CELDA_SALIDA
    beq  a0, t0, jugador_toco_salida_si

    li   a0, 0
    ret

jugador_toco_salida_si:
    li   a0, 1
    ret


# ================================================================
# Funcion: nivel_limpio
# Verifica si NINGUN enemigo esta vivo (todos los slots de la
# tabla enemigo_activo en 0). Requisito clasico de Bomberman: la
# salida solo funciona cuando el nivel esta "limpio".
# Parametros: ninguno
# Retorno:
#   a0: 1 si no queda ningun enemigo vivo, 0 si queda al menos uno
# ================================================================
nivel_limpio:
    la   t0, enemigo_activo
    li   t1, 0

nivel_limpio_loop:
    li   t2, MAX_ENEMIGOS
    bge  t1, t2, nivel_limpio_si

    lw   t3, 0(t0)
    bnez t3, nivel_limpio_no

    addi t0, t0, 4
    addi t1, t1, 1
    j    nivel_limpio_loop

nivel_limpio_si:
    li   a0, 1
    ret

nivel_limpio_no:
    li   a0, 0
    ret


# ================================================================
# Funcion: perder_vida
# Parametros: ninguno
# Retorno: void
# ================================================================
perder_vida:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)

    lw   t0, jugador_x
    srai s0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai s1, t0, TILE_SHIFT

    lw   t0, jugador_vidas
    addi t0, t0, -1
    la   t1, jugador_vidas
    sw   t0, 0(t1)

    blez t0, perder_vida_juego_terminado

    li   t0, SPAWN_COL
    slli t0, t0, TILE_SHIFT
    la   t1, jugador_x
    sw   t0, 0(t1)

    li   t0, SPAWN_FILA
    slli t0, t0, TILE_SHIFT
    la   t1, jugador_y
    sw   t0, 0(t1)

    li   t0, JUGADOR_INVULN_FRAMES
    la   t1, jugador_invuln
    sw   t0, 0(t1)

    mv   a0, s0
    mv   a1, s1
    jal  redibujar_celda

    li   a0, SPAWN_COL
    li   a1, SPAWN_FILA
    jal  redibujar_celda

    jal  pintar_hud_completo

    j    perder_vida_fin

perder_vida_juego_terminado:
    j    fin_programa

perder_vida_fin:
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: celda_bloqueada_para_enemigo
# Parametros:
#   a0: columna de tile propuesta
#   a1: fila de tile propuesta
#   a2: indice del enemigo que se esta moviendo
# Retorno:
#   a0: 1 si bloqueada, 0 si libre
# ================================================================
celda_bloqueada_para_enemigo:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2

    mv   a0, s0
    mv   a1, s1
    jal  celda_es_solida
    bnez a0, celda_bloqueada_para_enemigo_si

    lw   t0, jugador_invuln
    beqz t0, celda_bloqueada_para_enemigo_chequear_enemigos

    mv   a0, s0
    mv   a1, s1
    jal  jugador_esta_en_celda
    bnez a0, celda_bloqueada_para_enemigo_si

celda_bloqueada_para_enemigo_chequear_enemigos:
    mv   a0, s0
    mv   a1, s1
    jal  enemigo_en_celda
    beqz a0, celda_bloqueada_para_enemigo_no

    la   t0, enemigo_col
    slli t1, s2, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    bne  t2, s0, celda_bloqueada_para_enemigo_si

    la   t0, enemigo_fila
    add  t0, t0, t1
    lw   t2, 0(t0)
    bne  t2, s1, celda_bloqueada_para_enemigo_si

    j    celda_bloqueada_para_enemigo_no

celda_bloqueada_para_enemigo_si:
    li   a0, 1
    j    celda_bloqueada_para_enemigo_fin

celda_bloqueada_para_enemigo_no:
    li   a0, 0

celda_bloqueada_para_enemigo_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: numero_aleatorio
# Parametros:
#   a0: limite superior EXCLUSIVO (debe ser > 0)
# Retorno:
#   a0: numero aleatorio en [0, limite)
# ================================================================
numero_aleatorio:
    mv   a1, a0
    li   a0, 0
    li   a7, 42
    ecall
    ret


# ================================================================
# Funcion: elegir_direccion_aleatoria
# Parametros: ninguno
# Retorno:
#   a0: delta columna (-1, 0, o 1)
#   a1: delta fila (-1, 0, o 1)
# ================================================================
elegir_direccion_aleatoria:
    addi sp, sp, -4
    sw   ra, 0(sp)

    li   a0, 4
    jal  numero_aleatorio

    li   t0, 0
    beq  a0, t0, elegir_direccion_aleatoria_arriba
    li   t0, 1
    beq  a0, t0, elegir_direccion_aleatoria_abajo
    li   t0, 2
    beq  a0, t0, elegir_direccion_aleatoria_izquierda

    li   a0, 1
    li   a1, 0
    j    elegir_direccion_aleatoria_fin

elegir_direccion_aleatoria_arriba:
    li   a0, 0
    li   a1, -1
    j    elegir_direccion_aleatoria_fin

elegir_direccion_aleatoria_abajo:
    li   a0, 0
    li   a1, 1
    j    elegir_direccion_aleatoria_fin

elegir_direccion_aleatoria_izquierda:
    li   a0, -1
    li   a1, 0

elegir_direccion_aleatoria_fin:
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: elegir_direccion_persecucion
# Parametros:
#   a0: columna actual del enemigo
#   a1: fila actual del enemigo
# Retorno:
#   a0: delta columna del candidato PRIORITARIO
#   a1: delta fila del candidato PRIORITARIO
#   a2: delta columna del candidato SECUNDARIO (0 si no aplica)
#   a3: delta fila del candidato SECUNDARIO (0 si no aplica)
# ================================================================
elegir_direccion_persecucion:
    addi sp, sp, -8
    sw   s0, 0(sp)
    sw   s1, 4(sp)

    lw   t0, jugador_x
    srai t1, t0, TILE_SHIFT
    sub  s0, t1, a0

    lw   t0, jugador_y
    srai t1, t0, TILE_SHIFT
    sub  s1, t1, a1

    mv   t3, s0
    bgez t3, elegir_direccion_persecucion_abs_dx_lista
    sub  t3, zero, t3
elegir_direccion_persecucion_abs_dx_lista:

    mv   t4, s1
    bgez t4, elegir_direccion_persecucion_abs_dy_lista
    sub  t4, zero, t4
elegir_direccion_persecucion_abs_dy_lista:

    bge  t3, t4, elegir_direccion_persecucion_prioridad_x

    li   a0, 0
    bgtz s1, elegir_direccion_persecucion_py_abajo
    li   a1, -1
    j    elegir_direccion_persecucion_secundario_x
elegir_direccion_persecucion_py_abajo:
    li   a1, 1

elegir_direccion_persecucion_secundario_x:
    beqz s0, elegir_direccion_persecucion_sin_secundario
    li   a3, 0
    bgtz s0, elegir_direccion_persecucion_sx_derecha
    li   a2, -1
    j    elegir_direccion_persecucion_fin
elegir_direccion_persecucion_sx_derecha:
    li   a2, 1
    j    elegir_direccion_persecucion_fin

elegir_direccion_persecucion_prioridad_x:
    li   a1, 0
    bgtz s0, elegir_direccion_persecucion_px_derecha
    li   a0, -1
    j    elegir_direccion_persecucion_secundario_y
elegir_direccion_persecucion_px_derecha:
    li   a0, 1

elegir_direccion_persecucion_secundario_y:
    beqz s1, elegir_direccion_persecucion_sin_secundario
    li   a2, 0
    bgtz s1, elegir_direccion_persecucion_sy_abajo
    li   a3, -1
    j    elegir_direccion_persecucion_fin
elegir_direccion_persecucion_sy_abajo:
    li   a3, 1
    j    elegir_direccion_persecucion_fin

elegir_direccion_persecucion_sin_secundario:
    li   a2, 0
    li   a3, 0

elegir_direccion_persecucion_fin:
    lw   s1, 4(sp)
    lw   s0, 0(sp)
    addi sp, sp, 8
    ret


# ================================================================
# Funcion: mover_enemigo
# Parametros:
#   a0: indice del enemigo en la tabla
# Retorno: void
# ================================================================
mover_enemigo:
    addi sp, sp, -36
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)
    sw   s4, 20(sp)
    sw   s5, 24(sp)
    sw   s6, 28(sp)
    sw   s7, 32(sp)

    mv   s0, a0

    la   t0, enemigo_col
    slli t1, s0, 2
    add  t0, t0, t1
    lw   s1, 0(t0)

    la   t0, enemigo_fila
    add  t0, t0, t1
    lw   s2, 0(t0)

    la   t0, enemigo_tipo
    add  t0, t0, t1
    lw   s5, 0(t0)

    li   t0, ENEMIGO_TIPO_PERSEGUIDOR
    beq  s5, t0, mover_enemigo_perseguidor

    li   t0, ENEMIGO_TIPO_ALEATORIO
    beq  s5, t0, mover_enemigo_aleatorio_forzado

    la   t0, enemigo_dir_col
    add  t0, t0, t1
    lw   s3, 0(t0)
    la   t0, enemigo_dir_fila
    add  t0, t0, t1
    lw   s4, 0(t0)
    j    mover_enemigo_validar

mover_enemigo_aleatorio_forzado:
    jal  elegir_direccion_aleatoria
    mv   s3, a0
    mv   s4, a1
    j    mover_enemigo_validar

mover_enemigo_perseguidor:
    mv   a0, s1
    mv   a1, s2
    jal  elegir_direccion_persecucion
    mv   s3, a0
    mv   s4, a1
    mv   s6, a2
    mv   s7, a3

    add  t2, s1, s3
    add  t3, s2, s4
    mv   a0, t2
    mv   a1, t3
    mv   a2, s0
    jal  celda_bloqueada_para_enemigo
    beqz a0, mover_enemigo_aplicar

    or   t5, s6, s7
    beqz t5, mover_enemigo_validar

    mv   s3, s6
    mv   s4, s7
    add  t2, s1, s3
    add  t3, s2, s4
    mv   a0, t2
    mv   a1, t3
    mv   a2, s0
    jal  celda_bloqueada_para_enemigo
    beqz a0, mover_enemigo_aplicar

mover_enemigo_validar:
    add  t2, s1, s3
    add  t3, s2, s4

    mv   a0, t2
    mv   a1, t3
    mv   a2, s0
    jal  celda_bloqueada_para_enemigo
    beqz a0, mover_enemigo_aplicar

    jal  elegir_direccion_aleatoria
    mv   s3, a0
    mv   s4, a1

    add  t2, s1, s3
    add  t3, s2, s4

    mv   a0, t2
    mv   a1, t3
    mv   a2, s0
    jal  celda_bloqueada_para_enemigo
    bnez a0, mover_enemigo_fin

mover_enemigo_aplicar:
    la   t0, enemigo_dir_col
    slli t1, s0, 2
    add  t0, t0, t1
    sw   s3, 0(t0)
    la   t0, enemigo_dir_fila
    add  t0, t0, t1
    sw   s4, 0(t0)

    la   t0, enemigo_col
    add  t0, t0, t1
    add  t2, s1, s3
    sw   t2, 0(t0)
    la   t0, enemigo_fila
    add  t0, t0, t1
    add  t3, s2, s4
    sw   t3, 0(t0)

    mv   a0, s1
    mv   a1, s2
    jal  redibujar_celda

    add  a0, s1, s3
    add  a1, s2, s4
    jal  redibujar_celda

mover_enemigo_fin:
    lw   s7, 32(sp)
    lw   s6, 28(sp)
    lw   s5, 24(sp)
    lw   s4, 20(sp)
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 36
    ret


# ================================================================
# Funcion: actualizar_enemigos
# Parametros: ninguno
# Retorno: void
# ================================================================
actualizar_enemigos:
    addi sp, sp, -8
    sw   ra, 0(sp)
    sw   s0, 4(sp)

    lw   t0, contador_vueltas
    li   t1, ENEMIGO_MOVIMIENTO_INTERVALO_FRAMES
    rem  t0, t0, t1
    bnez t0, actualizar_enemigos_fin

    li   s0, 0

actualizar_enemigos_loop:
    li   t0, MAX_ENEMIGOS
    bge  s0, t0, actualizar_enemigos_fin

    la   t0, enemigo_activo
    slli t1, s0, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, actualizar_enemigos_siguiente

    mv   a0, s0
    jal  mover_enemigo

actualizar_enemigos_siguiente:
    addi s0, s0, 1
    j    actualizar_enemigos_loop

actualizar_enemigos_fin:
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 8
    ret


# ================================================================
# Funcion: spawn_enemigo
# Parametros:
#   a0: columna de tile inicial
#   a1: fila de tile inicial
#   a2: tipo de enemigo (ENEMIGO_TIPO_*)
# Retorno: void
# ================================================================
spawn_enemigo:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2

    la   a0, enemigo_activo
    li   a1, MAX_ENEMIGOS
    jal  buscar_slot_libre
    mv   s3, a0
    blt  s3, zero, spawn_enemigo_fin

    la   t0, enemigo_activo
    slli t1, s3, 2
    add  t0, t0, t1
    li   t2, 1
    sw   t2, 0(t0)

    la   t0, enemigo_tipo
    add  t0, t0, t1
    sw   s2, 0(t0)

    la   t0, enemigo_col
    add  t0, t0, t1
    sw   s0, 0(t0)

    la   t0, enemigo_fila
    add  t0, t0, t1
    sw   s1, 0(t0)

    la   t0, enemigo_dir_col
    add  t0, t0, t1
    li   t2, 1
    sw   t2, 0(t0)
    la   t0, enemigo_dir_fila
    add  t0, t0, t1
    sw   zero, 0(t0)

    mv   a0, s0
    mv   a1, s1
    jal  redibujar_celda

spawn_enemigo_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: spawn_enemigos_del_nivel
# Crea los 3 enemigos (uno de cada tipo) en sus posiciones de
# spawn fijas. Las mismas 3 coordenadas (col,fila) son validas
# para los 3 niveles: se verifico por codigo, al generar cada
# mapa, que esas celdas caen en CELDA_VACIA y en la misma
# componente conectada que el spawn del jugador. Se llama tanto
# desde main (nivel 1 inicial) como desde avanzar_nivel (nivel
# 2 y 3).
# Parametros: ninguno
# Retorno: void
# ================================================================
spawn_enemigos_del_nivel:
    addi sp, sp, -4
    sw   ra, 0(sp)

    # Coordenadas (col,fila) para el mapa 13x13 (vuelto de 14x14).
    # Verificadas por codigo al generar los 3 mapas: caen en
    # CELDA_VACIA y en la misma componente conectada que el spawn
    # del jugador (1,1), en los 3 niveles.
    li   a0, 11
    li   a1, 3
    li   a2, ENEMIGO_TIPO_RECTO
    jal  spawn_enemigo

    li   a0, 1
    li   a1, 11
    li   a2, ENEMIGO_TIPO_ALEATORIO
    jal  spawn_enemigo

    li   a0, 10
    li   a1, 11
    li   a2, ENEMIGO_TIPO_PERSEGUIDOR
    jal  spawn_enemigo

    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: avanzar_nivel
# Se llama cuando el jugador pisa la salida con el nivel limpio de
# enemigos. Incrementa nivel_actual; si ya se completo el nivel 3,
# es VICTORIA (fin del juego, distinto de game over -- por ahora
# tambien salta a fin_programa, igual que perder_vida cuando se
# acaban las vidas; una pantalla de victoria real queda para la
# etapa de pulido). Si quedan niveles, carga el mapa siguiente,
# limpia bombas/explosiones/powerups/enemigos del nivel anterior
# (via cargar_nivel), reposiciona al jugador en el spawn, y
# redibuja todo. Las vidas, rango, y max_bombas del jugador NO se
# tocan: persisten entre niveles segun lo decidido.
# Parametros: ninguno
# Retorno: void
# ================================================================
avanzar_nivel:
    addi sp, sp, -4
    sw   ra, 0(sp)

    lw   t0, nivel_actual
    li   t1, 3
    bge  t0, t1, avanzar_nivel_victoria

    addi t0, t0, 1
    la   t1, nivel_actual
    sw   t0, 0(t1)

    jal  cargar_nivel

    # Reposicionar al jugador en el spawn del nuevo nivel
    li   t0, SPAWN_COL
    slli t0, t0, TILE_SHIFT
    la   t1, jugador_x
    sw   t0, 0(t1)

    li   t0, SPAWN_FILA
    slli t0, t0, TILE_SHIFT
    la   t1, jugador_y
    sw   t0, 0(t1)

    jal  limpiar_pantalla
    jal  pintar_fondo_hud
    jal  pintar_mapa
    jal  pintar_hud_completo

    lw   a0, jugador_x
    lw   a1, jugador_y
    li   a2, COLOR_JUGADOR
    li   a3, TILE_SIZE
    li   a4, TILE_SIZE
    jal  pintar_bloque_fb

    jal  spawn_enemigos_del_nivel

    lw   ra, 0(sp)
    addi sp, sp, 4
    ret

avanzar_nivel_victoria:
    # Salto directo a fin_programa, mismo patron que
    # perder_vida_juego_terminado: es seguro porque fin_programa
    # es un loop infinito que nunca retorna, asi que no importa
    # que el stack frame de avanzar_nivel quede sin desenrollar.
    j    fin_programa


# ================================================================
# Funcion: jugador_toco_enemigo
# Parametros: ninguno (lee jugador_x/jugador_y)
# Retorno:
#   a0: 1 si hay un enemigo ahi, 0 si no
# ================================================================
jugador_toco_enemigo:
    lw   t0, jugador_x
    srai a0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai a1, t0, TILE_SHIFT

    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  enemigo_en_celda
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret


# ================================================================
# Funcion: matar_enemigos_en_fuego
# Parametros: ninguno
# Retorno: void
# ================================================================
matar_enemigos_en_fuego:
    addi sp, sp, -8
    sw   ra, 0(sp)
    sw   s0, 4(sp)

    li   s0, 0

matar_enemigos_en_fuego_loop:
    li   t0, MAX_ENEMIGOS
    bge  s0, t0, matar_enemigos_en_fuego_fin

    la   t0, enemigo_activo
    slli t1, s0, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    beqz t2, matar_enemigos_en_fuego_siguiente

    la   t3, enemigo_col
    add  t3, t3, t1
    lw   a0, 0(t3)
    la   t3, enemigo_fila
    add  t3, t3, t1
    lw   a1, 0(t3)

    jal  celda_tipo
    li   t3, CELDA_EXPLOSION
    bne  a0, t3, matar_enemigos_en_fuego_siguiente

    la   t0, enemigo_activo
    slli t1, s0, 2
    add  t0, t0, t1
    sw   zero, 0(t0)

    la   t3, enemigo_col
    add  t3, t3, t1
    lw   a0, 0(t3)
    la   t3, enemigo_fila
    add  t3, t3, t1
    lw   a1, 0(t3)
    jal  redibujar_celda

matar_enemigos_en_fuego_siguiente:
    addi s0, s0, 1
    j    matar_enemigos_en_fuego_loop

matar_enemigos_en_fuego_fin:
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 8
    ret


# ================================================================
# Funcion: parpadear_jugador
# Parametros: ninguno (lee jugador_x/jugador_y y contador_vueltas)
# Retorno: void
# ================================================================
parpadear_jugador:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)

    lw   t0, jugador_x
    srai a0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai a1, t0, TILE_SHIFT

    lw   t0, contador_vueltas
    li   t1, INVULN_PARPADEO_INTERVALO
    div  t0, t0, t1
    andi t0, t0, 1
    bnez t0, parpadear_jugador_oculto

    jal  redibujar_celda
    j    parpadear_jugador_fin

parpadear_jugador_oculto:
    mv   s0, a0
    mv   s1, a1
    jal  celda_tipo
    jal  celda_color
    mv   a2, a0
    mv   a0, s0
    mv   a1, s1
    li   a3, 1
    li   a4, 1
    jal  pintar_bloque_tiles

parpadear_jugador_fin:
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: crear_powerup_suelo
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
#   a2: tipo de power-up (POWERUP_LLAMA, POWERUP_BOMBA_EXTRA, o POWERUP_VIDA_EXTRA)
# Retorno: void
# ================================================================
crear_powerup_suelo:
    addi sp, sp, -20
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)
    sw   s2, 12(sp)
    sw   s3, 16(sp)

    mv   s0, a0
    mv   s1, a1
    mv   s2, a2

    la   a0, powerup_suelo_activo
    li   a1, MAX_POWERUPS_SUELO
    jal  buscar_slot_libre
    mv   s3, a0
    blt  s3, zero, crear_powerup_suelo_fin

    la   t0, powerup_suelo_activo
    slli t1, s3, 2
    add  t0, t0, t1
    li   t2, 1
    sw   t2, 0(t0)

    la   t0, powerup_suelo_tipo
    add  t0, t0, t1
    sw   s2, 0(t0)

    la   t0, powerup_suelo_col
    add  t0, t0, t1
    sw   s0, 0(t0)

    la   t0, powerup_suelo_fila
    add  t0, t0, t1
    sw   s1, 0(t0)

    mv   a0, s0
    mv   a1, s1
    jal  redibujar_celda

crear_powerup_suelo_fin:
    lw   s3, 16(sp)
    lw   s2, 12(sp)
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 20
    ret


# ================================================================
# Funcion: recolectar_powerups
# Parametros: ninguno (lee jugador_x/jugador_y)
# Retorno: void
# ================================================================
recolectar_powerups:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)

    lw   t0, jugador_x
    srai s0, t0, TILE_SHIFT
    lw   t0, jugador_y
    srai s1, t0, TILE_SHIFT

    mv   a0, s0
    mv   a1, s1
    jal  powerup_suelo_en_celda
    beqz a0, recolectar_powerups_fin

    li   t0, POWERUP_LLAMA
    beq  a1, t0, recolectar_powerups_llama
    li   t0, POWERUP_BOMBA_EXTRA
    beq  a1, t0, recolectar_powerups_bomba_extra
    li   t0, POWERUP_VIDA_EXTRA
    beq  a1, t0, recolectar_powerups_vida_extra
    j    recolectar_powerups_eliminar

recolectar_powerups_llama:
    lw   t0, jugador_rango
    li   t1, JUGADOR_RANGO_TOPE
    bge  t0, t1, recolectar_powerups_eliminar
    addi t0, t0, 1
    la   t1, jugador_rango
    sw   t0, 0(t1)
    j    recolectar_powerups_eliminar

recolectar_powerups_bomba_extra:
    lw   t0, jugador_max_bombas
    li   t1, JUGADOR_MAX_BOMBAS_TOPE
    bge  t0, t1, recolectar_powerups_eliminar
    addi t0, t0, 1
    la   t1, jugador_max_bombas
    sw   t0, 0(t1)
    j    recolectar_powerups_eliminar

recolectar_powerups_vida_extra:
    lw   t0, jugador_vidas
    li   t1, JUGADOR_VIDAS_TOPE
    bge  t0, t1, recolectar_powerups_eliminar
    addi t0, t0, 1
    la   t1, jugador_vidas
    sw   t0, 0(t1)

recolectar_powerups_eliminar:
    mv   a0, s0
    mv   a1, s1
    jal  eliminar_powerup_suelo

    jal  pintar_hud_completo

recolectar_powerups_fin:
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret


# ================================================================
# Funcion: eliminar_powerup_suelo
# Parametros:
#   a0: columna de tile
#   a1: fila de tile
# Retorno: void
# ================================================================
eliminar_powerup_suelo:
    addi sp, sp, -12
    sw   ra, 0(sp)
    sw   s0, 4(sp)
    sw   s1, 8(sp)

    mv   s0, a0
    mv   s1, a1

    la   t0, powerup_suelo_activo
    li   t1, 0

eliminar_powerup_suelo_buscar:
    li   t2, MAX_POWERUPS_SUELO
    bge  t1, t2, eliminar_powerup_suelo_fin

    slli t3, t1, 2
    add  t4, t0, t3
    lw   t5, 0(t4)
    beqz t5, eliminar_powerup_suelo_siguiente

    la   t4, powerup_suelo_col
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, s0, eliminar_powerup_suelo_siguiente

    la   t4, powerup_suelo_fila
    add  t4, t4, t3
    lw   t5, 0(t4)
    bne  t5, s1, eliminar_powerup_suelo_siguiente

    la   t4, powerup_suelo_activo
    add  t4, t4, t3
    sw   zero, 0(t4)

    mv   a0, s0
    mv   a1, s1
    jal  redibujar_celda
    j    eliminar_powerup_suelo_fin

eliminar_powerup_suelo_siguiente:
    addi t1, t1, 1
    j    eliminar_powerup_suelo_buscar

eliminar_powerup_suelo_fin:
    lw   s1, 8(sp)
    lw   s0, 4(sp)
    lw   ra, 0(sp)
    addi sp, sp, 12
    ret
