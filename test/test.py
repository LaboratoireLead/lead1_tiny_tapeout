# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# Tests de la sortie audio I2S et du générateur de sons de test.
#
# Un décodeur I2S écrit en Python joue le rôle du convertisseur audio : à chaque front
# montant de BCLK il lit SD, reconstitue les mots de 32 bits de chaque canal, vérifie le
# format, puis compare les échantillons au modèle Python du générateur (au bit près).
# Le son capturé est écrit dans test/output/*.wav (24 bits, 48 kHz) pour l'écoute.
#
# Durée simulée : variable d'environnement DUREE_MS (20 ms par défaut, 5 ms au niveau portes).
# Icarus simule ≈ 0,75 million de cycles par seconde : 1 s de son ≈ 22 min de calcul.
#   cd test && PATH=../.venv/bin:$PATH make DUREE_MS=200 TRACE=0     → 0,2 s de son (≈ 4 min)

import math
import os
import wave

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from cocotb.utils import get_sim_time

PERIODE_PS = 20344          # ≈ 49,152 MHz (20,345 ns arrondi à un nombre pair de ps pour cocotb)
CYCLES_PAR_TRAME = 1024     # 64 BCLK × 16 cycles
FE = 48000
INC_G, INC_D = 153791, 230687   # 440 Hz et 660 Hz (phase sur 24 bits)
DOSSIER_SORTIE = os.path.join(os.path.dirname(__file__), "output")

# Quart d'onde identique à src/generateur_test.v
QUART = [round(32767 * math.sin(2 * math.pi * (i + 0.5) / 256)) for i in range(64)]


def sinus_256(indice):
    quadrant, j = indice >> 6, indice & 63
    if quadrant & 1:
        j = 63 - j
    q = QUART[j]
    return -q if quadrant & 2 else q


def modele(inc, n):
    """Échantillon n (24 bits signés) produit par le générateur de test."""
    phase = (n * inc) & 0xFFFFFF
    return (sinus_256(phase >> 16) << 8) >> 2


def signe(mot, bits):
    return mot - (1 << bits) if mot & (1 << (bits - 1)) else mot


class DecodeurI2S:
    """Lit BCLK / LRCLK / SD et range les mots de 32 bits de chaque canal."""

    def __init__(self, dut):
        self.dut = dut
        self.gauche, self.droite = [], []
        self.erreurs = []
        self.actif = True

    async def tourner(self):
        mot, nb, lr_prec = 0, 0, None
        while self.actif:
            await RisingEdge(self.dut.bclk)
            lr, bit = int(self.dut.lrclk.value), int(self.dut.sd.value)
            mot = ((mot << 1) | bit) & 0xFFFFFFFF
            nb += 1
            if lr_prec is not None and lr != lr_prec:
                # en I2S, le bit lu au premier front après le changement de LRCLK est le
                # dernier bit (poids faible) du canal précédent
                if nb == 32:
                    (self.gauche if lr_prec == 0 else self.droite).append(signe(mot, 32))
                elif self.gauche or self.droite:
                    self.erreurs.append(f"mot de {nb} bits au lieu de 32")
                mot, nb = 0, 0
            lr_prec = lr


def ecrire_wav(nom, gauche, droite):
    os.makedirs(DOSSIER_SORTIE, exist_ok=True)
    chemin = os.path.join(DOSSIER_SORTIE, nom)
    with wave.open(chemin, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(3)
        w.setframerate(FE)
        donnees = bytearray()
        for g, d in zip(gauche, droite):
            for v in (g >> 8, d >> 8):          # 32 bits → 24 bits
                donnees += (v & 0xFFFFFF).to_bytes(3, "little")
        w.writeframes(bytes(donnees))
    return chemin


async def demarrer(dut, son_test):
    cocotb.start_soon(Clock(dut.clk, PERIODE_PS, unit="ps").start())
    dut.ena.value = 1
    dut.ui_in.value = 0b1000 if son_test else 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


def trouver_decalage(captures, inc, essais=8):
    """Indice du premier échantillon capturé dans la suite du modèle (le décodeur
    commence en cours de trame, et la synchronisation de ui_in[3] prend 2 cycles)."""
    for k in range(essais):
        if all(captures[i] >> 8 == modele(inc, k + i) for i in range(min(20, len(captures)))):
            return k
    return None


@cocotb.test()
async def test_format_i2s(dut):
    """Fréquences de BCLK, LRCLK, MCLK et position des bits dans la trame."""
    await demarrer(dut, son_test=True)
    await ClockCycles(dut.clk, 3 * CYCLES_PAR_TRAME)

    # LRCLK : une période = 1 024 cycles (48 kHz à 49,152 MHz)
    await FallingEdge(dut.lrclk)
    t0 = get_sim_time("ps")
    await FallingEdge(dut.lrclk)
    t1 = get_sim_time("ps")
    assert t1 - t0 == CYCLES_PAR_TRAME * PERIODE_PS, f"période de LRCLK : {(t1 - t0) / PERIODE_PS} cycles"

    # BCLK : 16 cycles, MCLK : 4 cycles
    for signal, attendu in ((dut.bclk, 16), (dut.mclk, 4)):
        await RisingEdge(signal)
        t0 = get_sim_time("ps")
        await RisingEdge(signal)
        assert get_sim_time("ps") - t0 == attendu * PERIODE_PS, f"période de {signal._name}"

    # LRCLK et SD ne changent qu'au front descendant de BCLK
    for _ in range(200):
        await RisingEdge(dut.clk)
        bclk_avant, lr_avant, sd_avant = int(dut.bclk.value), int(dut.lrclk.value), int(dut.sd.value)
        await RisingEdge(dut.clk)
        if int(dut.lrclk.value) != lr_avant or int(dut.sd.value) != sd_avant:
            assert bclk_avant == 1 and int(dut.bclk.value) == 0, "LRCLK ou SD change hors du front descendant de BCLK"
    dut._log.info("format I2S correct : BCLK 3,072 MHz, LRCLK 48 kHz, MCLK 12,288 MHz")


@cocotb.test()
async def test_son_de_test(dut):
    """Sinus 440 Hz à gauche et 660 Hz à droite, comparés au modèle au bit près ; WAV écrit."""
    # 20 ms par défaut (≈ 30 s de simulation) ; 5 ms au niveau portes (GATES=yes), bien plus lent
    duree_ms = float(os.environ.get("DUREE_MS", "5" if os.environ.get("GATES") == "yes" else "20"))
    n_trames = int(duree_ms * FE / 1000)

    await demarrer(dut, son_test=True)
    dec = DecodeurI2S(dut)
    cocotb.start_soon(dec.tourner())
    await ClockCycles(dut.clk, (n_trames + 2) * CYCLES_PAR_TRAME)
    dec.actif = False

    assert not dec.erreurs, dec.erreurs[:5]
    n = min(len(dec.gauche), len(dec.droite))
    assert n >= n_trames - 1, f"seulement {n} trames décodées sur {n_trames}"
    chemin = ecrire_wav("son_test_440_660.wav", dec.gauche[:n], dec.droite[:n])

    # les 8 bits de poids faible du mot de 32 bits doivent être nuls
    assert all(v & 0xFF == 0 for v in dec.gauche[:n] + dec.droite[:n]), "bits de bourrage non nuls"

    # on saute les premières trames (silence avant la prise en compte de ui_in[3])
    debut = next(i for i in range(n) if dec.gauche[i] != 0)
    g, d = dec.gauche[debut:n], dec.droite[debut:n]
    kg, kd = trouver_decalage(g, INC_G), trouver_decalage(d, INC_D)
    assert kg is not None, "canal gauche différent du modèle (sinus 440 Hz)"
    assert kd is not None, "canal droit différent du modèle (sinus 660 Hz)"
    assert kg == kd, f"canaux décalés : {kg} et {kd} échantillons"
    faux = [i for i in range(len(g)) if g[i] >> 8 != modele(INC_G, kg + i) or d[i] >> 8 != modele(INC_D, kd + i)]
    assert not faux, f"{len(faux)} échantillons différents du modèle, le premier à l'indice {faux[0]}"

    crete = max(abs(v >> 8) for v in g) / (1 << 23)
    dut._log.info(f"{n} trames ({n / FE * 1000:.1f} ms) identiques au modèle ; crête "
                  f"{20 * math.log10(crete):.1f} dBFS ; WAV : {chemin}")


@cocotb.test()
async def test_silence(dut):
    """Sans le son de test (ui_in[3] = 0), la sortie est muette mais l'I2S tourne."""
    await demarrer(dut, son_test=False)
    dec = DecodeurI2S(dut)
    cocotb.start_soon(dec.tourner())
    await ClockCycles(dut.clk, 20 * CYCLES_PAR_TRAME)
    dec.actif = False
    assert not dec.erreurs, dec.erreurs[:5]
    assert len(dec.gauche) >= 18, f"seulement {len(dec.gauche)} trames"
    assert all(v == 0 for v in dec.gauche + dec.droite), "son en sortie alors que le son de test est coupé"
