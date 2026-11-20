# Tables et paramètres de la sonde de vitesse de la piste B (src/sonde_b.v).
# Ce module sert à la fois à générer src/sonde_tables.v (python3 tables_sonde.py) et de
# modèle de référence au bit près dans test/test.py : une seule source pour les deux.
# SPDX-License-Identifier: Apache-2.0

import math

# Quart d'onde du sinus : 256 points sur un quart de période (1 024 points par période),
# valeur Q[i] = arrondi(32767 · sin(2π i / 1024)) et pente D[i] = Q[i+1] − Q[i] (0 à 201)
# pour l'interpolation linéaire (comme lireSinus du worklet, table plus petite).
Q = [round(32767 * math.sin(2 * math.pi * i / 1024)) for i in range(257)]
D = [Q[i + 1] - Q[i] for i in range(256)]
Q = Q[:256]

# Table de différence du timbre « scie2 » (worklet : construireDifference) : harmoniques 2 à
# 10 en 1/k², 256 points par période, même échelle que le sinus (32767 = 1).
DIF = [round(32767 * sum(math.sin(2 * math.pi * k * n / 256) / k ** 2 for k in range(2, 11))) for n in range(256)]

# Enveloppe percussive par bloc de 16 échantillons (worklet : enveloppePerc, F = 99,
# montée 18 blocs) : 128 valeurs sur 16 bits, nulles au-delà du bloc 95.
def enveloppe_perc(a, F=99, montee=18):
    fin40, fin = 90 * F / 99, 95 * F / 99
    if a < 0 or a >= fin:
        return 0.0
    if a < montee:
        return 0.5 - 0.5 * math.cos(math.pi * a / montee)
    e = math.exp(-2 * math.log(10) / (fin40 - montee) * (a - montee))
    if a >= fin40:
        e *= 0.5 + 0.5 * math.cos(math.pi * (a - fin40) / (fin - fin40))
    return e

ENV = [round(65535 * enveloppe_perc(a)) for a in range(128)]

# Quatre pixels d'essai (8 oscillateurs : pixel p → oscillateurs 2p gauche et 2p + 1 droit)
FREQ = [400, 600, 900, 1200]                     # Hz
INC = [round(f * 2 ** 24 / 48000) for f in FREQ]  # incrément de phase sur 24 bits
W = [0, 5, 10, 15]                               # poids du timbre (sur 15)
GAIN = [40000, 28000, 30000, 30000, 20000, 26000, 24000, 18000]  # par oscillateur (ILD)

BLOCS_FRAME = 99


def ecrire_verilog(chemin):
    def rom(nom, largeur, valeurs, signe=False, abits=8):
        t = "signed " if signe else ""
        l = [f"module {nom} (\n    input  wire [{abits - 1}:0] a,\n    output reg  {t}[{largeur - 1}:0] v\n);\n  always @(*) begin\n    case (a)"]
        for i, x in enumerate(valeurs):
            lit = f"-{largeur}'sd{-x}" if x < 0 else (f"{largeur}'sd{x}" if signe else f"{largeur}'d{x}")
            l.append(f"      {abits}'d{i}: v = {lit};")
        l.append(f"      default: v = 0;\n    endcase\n  end\nendmodule\n")
        return "\n".join(l)
    with open(chemin, "w", encoding="utf-8") as f:
        f.write("// Fichier produit par test/tables_sonde.py — ne pas modifier à la main.\n")
        f.write("// SPDX-License-Identifier: Apache-2.0\n`default_nettype none\n\n")
        f.write(rom("sonde_rom_q", 16, Q) + "\n")
        f.write(rom("sonde_rom_d", 8, D) + "\n")
        f.write(rom("sonde_rom_dif", 16, DIF, signe=True) + "\n")
        f.write(rom("sonde_rom_env", 16, ENV, abits=7) + "\n")


if __name__ == "__main__":
    import os
    ecrire_verilog(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "sonde_tables.v"))
    print("max D", max(D), "max |DIF|", max(abs(x) for x in DIF), "ENV[0..3]", ENV[:4], "ENV[94..96]", ENV[94:97])
