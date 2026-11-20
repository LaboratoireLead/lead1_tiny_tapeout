/*
 * Synthétiseur additif : module de tête Tiny Tapeout.
 *
 * Étape 1 : sortie audio I2S et générateur de sons de test (sinus 440 Hz à gauche,
 * 660 Hz à droite), activé par ui_in[3]. Le synthétiseur lui-même viendra ensuite.
 *
 * Broches :
 *   ui_in[0..2]  lien SPI des mises à jour (CS, SCK, MOSI) — pas encore utilisé
 *   ui_in[3]     1 = son de test, 0 = silence
 *   ui_in[4]     1 = sonde de vitesse de la piste B (4 pixels d'essai), prioritaire sur ui_in[3]
 *   uo_out[0..3] I2S vers la rangée du haut du Digilent Pmod I2S2 (convertisseur CS4344) :
 *                uo_out[0] MCLK (clk / 4 = 256 fs, obligatoire pour le CS4344)
 *                uo_out[1] LRCLK, uo_out[2] BCLK (SCLK), uo_out[3] SD (SDIN)
 *   uo_out[4..7] à 0 (rangée du bas du Pmod I2S2 : CAN CS5343, non utilisé)
 *   uio[0..7]    QSPI Pmod — pas encore utilisé, laissé en entrée
 *
 * Horloge prévue : 49,152 MHz (1 024 × 48 kHz). À une horloge plus lente (FPGA), le son
 * de test garde sa forme mais toutes les fréquences baissent dans le même rapport.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_laboratoirelead_synth (
    input  wire [7:0] ui_in,    // entrées
    output wire [7:0] uo_out,   // sorties
    input  wire [7:0] uio_in,   // broches bidirectionnelles : entrée
    output wire [7:0] uio_out,  // broches bidirectionnelles : sortie
    output wire [7:0] uio_oe,   // broches bidirectionnelles : 1 = sortie
    input  wire       ena,      // toujours à 1 quand le projet est alimenté
    input  wire       clk,      // horloge
    input  wire       rst_n     // remise à zéro, active à 0
);

  // Entrées de choix resynchronisées (elles viennent de l'extérieur, sans lien avec clk)
  reg [1:0] sync_test, sync_sonde;
  always @(posedge clk) begin
    if (!rst_n) begin
      sync_test  <= 2'b00;
      sync_sonde <= 2'b00;
    end else begin
      sync_test  <= {sync_test[0], ui_in[3]};
      sync_sonde <= {sync_sonde[0], ui_in[4]};
    end
  end

  wire               pas;
  wire signed [23:0] test_g, test_d, sonde_g, sonde_d;
  reg  signed [23:0] gauche, droite;

  generateur_test u_test (
      .clk   (clk),
      .rst_n (rst_n),
      .actif (sync_test[1]),
      .pas   (pas),
      .gauche(test_g),
      .droite(test_d)
  );

  sonde_voie_b u_sonde (
      .clk   (clk),
      .rst_n (rst_n),
      .pas   (pas),
      .gauche(sonde_g),
      .droite(sonde_d)
  );

  always @(posedge clk) begin
    gauche <= sync_sonde[1] ? sonde_g : test_g;
    droite <= sync_sonde[1] ? sonde_d : test_d;
  end

  wire bclk, lrclk, sd, mclk;

  i2s_tx #(.DIV_BCLK(16)) u_i2s (
      .clk   (clk),
      .rst_n (rst_n),
      .gauche(gauche),
      .droite(droite),
      .pas   (pas),
      .bclk  (bclk),
      .lrclk (lrclk),
      .sd    (sd),
      .mclk  (mclk)
  );

  assign uo_out  = {4'b0000, sd, bclk, lrclk, mclk};  // brochage du Pmod I2S2
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  // Entrées pas encore utilisées (évite les avertissements)
  wire _inutilise = &{ena, ui_in[7:5], ui_in[2:0], uio_in, 1'b0};

endmodule
