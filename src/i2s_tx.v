/*
 * Émetteur I2S stéréo (format I2S standard, Philips).
 *
 * - BCLK = clk / DIV_BCLK ; 64 BCLK par trame (2 × 32 bits) : LRCLK = BCLK / 64.
 *   À 49,152 MHz et DIV_BCLK = 16 : BCLK = 3,072 MHz, LRCLK = 48 kHz.
 * - LRCLK = 0 : canal gauche, LRCLK = 1 : canal droit.
 * - Données changées au front descendant de BCLK, lues par le convertisseur au front
 *   montant ; bit de poids fort en premier, un BCLK après le changement de LRCLK.
 * - Échantillons de 24 bits signés, envoyés en tête du mot de 32 bits (8 zéros derrière).
 * - MCLK = clk / 4 (12,288 MHz = 256 fs à 49,152 MHz) : indispensable au CS4344 du Pmod I2S2.
 * - Toutes les sorties sont des bascules : pas de parasites sur les broches.
 * - Les comparaisons (position dans la période de BCLK, numéro du bit) sont calculées un
 *   cycle à l'avance et mémorisées dans des bascules : en GF180 au coin lent, comparer puis
 *   charger le registre à décalage dans le même cycle dépassait 20 ns (E-386).
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module i2s_tx #(
    parameter integer DIV_BCLK = 16  // pair, au moins 4
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [23:0] gauche,
    input  wire signed [23:0] droite,
    output reg                pas,     // impulsion d'un cycle : échantillons pris, préparer les suivants
    output reg                bclk,
    output reg                lrclk,
    output reg                sd,
    output wire               mclk
);

  localparam integer LP = $clog2(DIV_BCLK);

  reg [LP-1:0] p;       // position dans la période de BCLK
  reg [5:0]    b;       // numéro du bit dans la trame (0 à 63)
  reg [31:0]   reg_dec; // registre à décalage du mot en cours
  reg [23:0]   gauche_memo, droite_memo;
  reg [1:0]    div_mclk;

  wire [5:0] b_suiv = b + 6'd1;

  // Indicateurs préparés un cycle à l'avance (vrais pendant le cycle où ils servent)
  reg monte, descend;            // ce cycle : front montant / descendant de BCLK
  reg vers_0, vers_1, vers_33;   // le prochain bit sera le n° 0 / 1 / 33
  always @(posedge clk) begin
    if (!rst_n) begin
      monte   <= 1'b0;
      descend <= 1'b0;
      vers_0  <= 1'b0;
      vers_1  <= 1'b0;
      vers_33 <= 1'b0;
    end else begin
      monte   <= (p == DIV_BCLK / 2 - 2);
      descend <= (p == DIV_BCLK - 2);
      // b ne change qu'au front descendant : ces valeurs sont stables bien avant l'usage
      vers_0  <= (b == 6'd63);
      vers_1  <= (b == 6'd0);
      vers_33 <= (b == 6'd32);
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      p           <= 0;
      b           <= 6'd63;
      bclk        <= 1'b0;
      lrclk       <= 1'b1;
      sd          <= 1'b0;
      reg_dec     <= 32'd0;
      gauche_memo <= 24'd0;
      droite_memo <= 24'd0;
      pas         <= 1'b0;
    end else begin
      pas <= 1'b0;
      if (monte) begin
        bclk <= 1'b1;                       // front montant : le convertisseur lit sd
        p    <= p + 1'b1;
      end else if (descend) begin
        // front descendant : passage au bit b_suiv
        p     <= 0;
        b     <= b_suiv;
        bclk  <= 1'b0;
        lrclk <= b_suiv[5];
        if (vers_0) begin
          // début de trame : les deux échantillons sont pris ensemble
          gauche_memo <= gauche;
          droite_memo <= droite;
          pas         <= 1'b1;
        end
        if (vers_1) begin
          sd      <= gauche_memo[23];
          reg_dec <= {gauche_memo[22:0], 9'd0};
        end else if (vers_33) begin
          sd      <= droite_memo[23];
          reg_dec <= {droite_memo[22:0], 9'd0};
        end else begin
          sd      <= reg_dec[31];
          reg_dec <= {reg_dec[30:0], 1'b0};
        end
      end else begin
        p <= p + 1'b1;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst_n) div_mclk <= 2'd0;
    else        div_mclk <= div_mclk + 2'd1;
  end
  assign mclk = div_mclk[1];

endmodule
