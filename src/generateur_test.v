/*
 * Générateur de sons de test : un sinus par canal (440 Hz à gauche, 660 Hz à droite),
 * sans mémoire externe ni RP2350, pour vérifier la sortie I2S seule.
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module generateur_test #(
    parameter [23:0] INC_G = 24'd153791,  // 440 Hz à 48 kHz : 440 × 2^24 / 48000
    parameter [23:0] INC_D = 24'd230687   // 660 Hz à 48 kHz
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               actif,    // 0 : sorties à zéro (silence)
    input  wire               pas,      // une impulsion par échantillon (48 kHz)
    output wire signed [23:0] gauche,
    output wire signed [23:0] droite
);

  reg [23:0] phase_g, phase_d;

  always @(posedge clk) begin
    if (!rst_n) begin
      phase_g <= 24'd0;
      phase_d <= 24'd0;
    end else if (pas) begin
      phase_g <= phase_g + INC_G;
      phase_d <= phase_d + INC_D;
    end
  end

  // Calcul en 3 étages de bascules : en GF180 au coin lent, le chemin phase → table →
  // changement de signe → sortie ne tient pas en un cycle de 20 ns (E-384). La phase ne
  // change qu'une fois par trame (1 024 cycles) : le retard de 3 cycles est sans effet.
  reg  [5:0]  j_g, j_d;              // étage 1 : case du quart d'onde (63 − j déjà appliqué)
  reg         neg1_g, neg1_d;        //           et signe (quadrants 2 et 3)
  wire [15:0] q_g, q_d;              // valeur du quart d'onde (sans signe)
  reg  [15:0] q_g_r, q_d_r;          // étage 2 : sortie de la table
  reg         neg_g, neg_d;          //           et signe (quadrants 2 et 3)
  reg  signed [23:0] gauche_r, droite_r;  // étage 3 : échantillons

  quart_sinus u_q_g (.j(j_g), .q(q_g));
  quart_sinus u_q_d (.j(j_d), .q(q_d));

  always @(posedge clk) begin
    if (!rst_n) begin
      j_g      <= 6'd0;  j_d      <= 6'd0;
      neg1_g   <= 1'b0;  neg1_d   <= 1'b0;
      q_g_r    <= 16'd0; q_d_r    <= 16'd0;
      neg_g    <= 1'b0;  neg_d    <= 1'b0;
      gauche_r <= 24'sd0; droite_r <= 24'sd0;
    end else begin
      j_g      <= phase_g[22] ? ~phase_g[21:16] : phase_g[21:16];  // 63 − j aux quadrants 1 et 3
      j_d      <= phase_d[22] ? ~phase_d[21:16] : phase_d[21:16];
      neg1_g   <= phase_g[23];
      neg1_d   <= phase_d[23];
      q_g_r    <= q_g;  neg_g <= neg1_g;
      q_d_r    <= q_d;  neg_d <= neg1_d;
      // 16 bits placés en tête des 24 bits, puis −12 dB (division par 4) pour ménager les oreilles
      gauche_r <= !actif ? 24'sd0 : neg_g ? -$signed({2'b00, q_g_r, 6'd0}) : $signed({2'b00, q_g_r, 6'd0});
      droite_r <= !actif ? 24'sd0 : neg_d ? -$signed({2'b00, q_d_r, 6'd0}) : $signed({2'b00, q_d_r, 6'd0});
    end
  end

  assign gauche = gauche_r;
  assign droite = droite_r;

endmodule

/*
 * Quart d'onde d'un sinus sur 256 points (valeur absolue) :
 * Q[i] = arrondi(32767 · sin(2π (i + 0,5) / 256)), table produite par un script Python
 * (même formule dans test/test.py pour la vérification au bit près). Le signe (quadrants
 * 2 et 3) et le sens de lecture (quadrants 1 et 3) sont traités par le module appelant.
 */
module quart_sinus (
    input  wire [5:0]  j,
    output reg  [15:0] q
);

  always @(*) begin
    case (j)
      6'd0 : q = 16'd402;
      6'd1 : q = 16'd1206;
      6'd2 : q = 16'd2009;
      6'd3 : q = 16'd2811;
      6'd4 : q = 16'd3612;
      6'd5 : q = 16'd4410;
      6'd6 : q = 16'd5205;
      6'd7 : q = 16'd5998;
      6'd8 : q = 16'd6786;
      6'd9 : q = 16'd7571;
      6'd10: q = 16'd8351;
      6'd11: q = 16'd9126;
      6'd12: q = 16'd9896;
      6'd13: q = 16'd10659;
      6'd14: q = 16'd11417;
      6'd15: q = 16'd12167;
      6'd16: q = 16'd12910;
      6'd17: q = 16'd13645;
      6'd18: q = 16'd14372;
      6'd19: q = 16'd15090;
      6'd20: q = 16'd15800;
      6'd21: q = 16'd16499;
      6'd22: q = 16'd17189;
      6'd23: q = 16'd17869;
      6'd24: q = 16'd18537;
      6'd25: q = 16'd19195;
      6'd26: q = 16'd19841;
      6'd27: q = 16'd20475;
      6'd28: q = 16'd21096;
      6'd29: q = 16'd21705;
      6'd30: q = 16'd22301;
      6'd31: q = 16'd22884;
      6'd32: q = 16'd23452;
      6'd33: q = 16'd24007;
      6'd34: q = 16'd24547;
      6'd35: q = 16'd25072;
      6'd36: q = 16'd25582;
      6'd37: q = 16'd26077;
      6'd38: q = 16'd26556;
      6'd39: q = 16'd27019;
      6'd40: q = 16'd27466;
      6'd41: q = 16'd27896;
      6'd42: q = 16'd28310;
      6'd43: q = 16'd28706;
      6'd44: q = 16'd29085;
      6'd45: q = 16'd29447;
      6'd46: q = 16'd29791;
      6'd47: q = 16'd30117;
      6'd48: q = 16'd30424;
      6'd49: q = 16'd30714;
      6'd50: q = 16'd30985;
      6'd51: q = 16'd31237;
      6'd52: q = 16'd31470;
      6'd53: q = 16'd31685;
      6'd54: q = 16'd31880;
      6'd55: q = 16'd32057;
      6'd56: q = 16'd32213;
      6'd57: q = 16'd32351;
      6'd58: q = 16'd32469;
      6'd59: q = 16'd32567;
      6'd60: q = 16'd32646;
      6'd61: q = 16'd32705;
      6'd62: q = 16'd32745;
      6'd63: q = 16'd32765;
      default: q = 16'd0;
    endcase
  end

endmodule
