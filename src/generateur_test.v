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

  wire signed [15:0] sin_g, sin_d;
  sinus_256 u_sin_g (.indice(phase_g[23:16]), .valeur(sin_g));
  sinus_256 u_sin_d (.indice(phase_d[23:16]), .valeur(sin_d));

  // 16 bits placés en tête des 24 bits, puis −12 dB (division par 4) pour ménager les oreilles
  assign gauche = actif ? ($signed({sin_g, 8'd0}) >>> 2) : 24'sd0;
  assign droite = actif ? ($signed({sin_d, 8'd0}) >>> 2) : 24'sd0;

endmodule

/*
 * Sinus sur 256 points à partir d'un quart d'onde de 64 valeurs :
 * Q[i] = arrondi(32767 · sin(2π (i + 0,5) / 256)), table produite par un script Python
 * (même formule dans test/test.py pour la vérification au bit près).
 */
module sinus_256 (
    input  wire        [7:0]  indice,
    output wire signed [15:0] valeur
);

  wire [1:0] quadrant = indice[7:6];
  wire [5:0] j        = quadrant[0] ? ~indice[5:0] : indice[5:0];  // 63 − j aux quadrants 1 et 3
  reg signed [15:0] q;

  always @(*) begin
    case (j)
      6'd0 : q = 16'sd402;
      6'd1 : q = 16'sd1206;
      6'd2 : q = 16'sd2009;
      6'd3 : q = 16'sd2811;
      6'd4 : q = 16'sd3612;
      6'd5 : q = 16'sd4410;
      6'd6 : q = 16'sd5205;
      6'd7 : q = 16'sd5998;
      6'd8 : q = 16'sd6786;
      6'd9 : q = 16'sd7571;
      6'd10: q = 16'sd8351;
      6'd11: q = 16'sd9126;
      6'd12: q = 16'sd9896;
      6'd13: q = 16'sd10659;
      6'd14: q = 16'sd11417;
      6'd15: q = 16'sd12167;
      6'd16: q = 16'sd12910;
      6'd17: q = 16'sd13645;
      6'd18: q = 16'sd14372;
      6'd19: q = 16'sd15090;
      6'd20: q = 16'sd15800;
      6'd21: q = 16'sd16499;
      6'd22: q = 16'sd17189;
      6'd23: q = 16'sd17869;
      6'd24: q = 16'sd18537;
      6'd25: q = 16'sd19195;
      6'd26: q = 16'sd19841;
      6'd27: q = 16'sd20475;
      6'd28: q = 16'sd21096;
      6'd29: q = 16'sd21705;
      6'd30: q = 16'sd22301;
      6'd31: q = 16'sd22884;
      6'd32: q = 16'sd23452;
      6'd33: q = 16'sd24007;
      6'd34: q = 16'sd24547;
      6'd35: q = 16'sd25072;
      6'd36: q = 16'sd25582;
      6'd37: q = 16'sd26077;
      6'd38: q = 16'sd26556;
      6'd39: q = 16'sd27019;
      6'd40: q = 16'sd27466;
      6'd41: q = 16'sd27896;
      6'd42: q = 16'sd28310;
      6'd43: q = 16'sd28706;
      6'd44: q = 16'sd29085;
      6'd45: q = 16'sd29447;
      6'd46: q = 16'sd29791;
      6'd47: q = 16'sd30117;
      6'd48: q = 16'sd30424;
      6'd49: q = 16'sd30714;
      6'd50: q = 16'sd30985;
      6'd51: q = 16'sd31237;
      6'd52: q = 16'sd31470;
      6'd53: q = 16'sd31685;
      6'd54: q = 16'sd31880;
      6'd55: q = 16'sd32057;
      6'd56: q = 16'sd32213;
      6'd57: q = 16'sd32351;
      6'd58: q = 16'sd32469;
      6'd59: q = 16'sd32567;
      6'd60: q = 16'sd32646;
      6'd61: q = 16'sd32705;
      6'd62: q = 16'sd32745;
      6'd63: q = 16'sd32765;
      default: q = 16'sd0;
    endcase
  end

  assign valeur = quadrant[1] ? -q : q;

endmodule
