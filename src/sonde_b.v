/*
 * Sonde de vitesse de la piste B (E-389) : la chaîne de calcul d'un oscillateur, en étages,
 * telle qu'elle tournera dans le synthétiseur, pour mesurer le timing en GF180.
 *
 * Organisation (montage, section 7) : le son est calculé par blocs de 16 échantillons.
 * Pendant un bloc (16 × 1 024 = 16 384 cycles), 1 024 « créneaux » de 16 cycles se suivent ;
 * chaque créneau traite un oscillateur (une oreille d'un pixel) et ajoute ses 16 échantillons
 * dans 16 accumulateurs (un par échantillon du bloc) de son oreille. Un échantillon d'un
 * oscillateur sort donc à chaque cycle.
 *
 * Par échantillon (comme blocB du worklet, en entiers) :
 *   phase θ += incrément (24 bits)
 *   s = sinus(θ) + w · différence_timbre(θ)          (sinus : quart d'onde interpolé)
 *   contribution = amplitude × s, l'amplitude variant linéairement sur le bloc
 * Par créneau (une fois par bloc et par oscillateur) :
 *   amplitude début et fin de bloc = gain × enveloppe_percussive(âge du grain en blocs)
 *
 * Simplifications de la sonde (pour la mesure de vitesse) : 8 oscillateurs d'essai en table
 * (4 pixels), les 1 016 autres créneaux à gain nul ; enveloppe percussive seule (pas de
 * partie plate ni de mélange p), pas de fondu enchaîné entre grains, pas d'ITD ; pas de
 * mémoire externe. Les opérations les plus coûteuses par échantillon sont toutes là.
 *
 * Sortie : 2 × 24 bits, l'échantillon du bloc précédent correspondant à la trame I2S en cours.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module sonde_voie_b (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               pas,      // impulsion de l'émetteur I2S : trame prise
    output reg  signed [23:0] gauche,
    output reg  signed [23:0] droite
);

  // ---------------------------------------------------------------------------------------
  // Cadencement : 16 trames I2S = 1 bloc. Le bloc commence juste après la prise de la trame
  // n° 15 : les tampons de sortie sont remplacés (≈ 50 cycles plus tard) bien avant la
  // prise de la trame n° 0 suivante (1 024 cycles).
  // ---------------------------------------------------------------------------------------
  reg  [3:0]  trame;      // numéro de la trame I2S dans le bloc
  reg  [13:0] cyc;        // cycle dans le bloc : créneau = cyc[13:4], échantillon = cyc[3:0]
  reg  [6:0]  age, age1;  // âge du grain (en blocs, 0 à 98) et âge + 1, pour le bloc en cours
  reg  [6:0]  ages, ages1;// les mêmes pour le bloc suivant
  reg         en_route;   // 0 jusqu'au premier bloc : compteur figé sur le dernier cycle
  wire        debut = pas && (trame == 4'd15);
  wire [9:0]  creneau = cyc[13:4];
  wire [3:0]  ech     = cyc[3:0];

  always @(posedge clk) begin
    if (!rst_n) begin
      trame <= 4'd0;
      cyc   <= 14'h3FFF;
      en_route <= 1'b0;
      age   <= 7'd98;  age1  <= 7'd99;
      ages  <= 7'd0;   ages1 <= 7'd1;
    end else begin
      if (pas) trame <= trame + 4'd1;
      if (debut) begin
        cyc   <= 14'd0;
        en_route <= 1'b1;
        age   <= ages;
        age1  <= ages1;
        ages  <= (ages == 7'd98) ? 7'd0 : ages + 7'd1;
        ages1 <= (ages == 7'd98) ? 7'd1 : ages1 + 7'd1;
      end else if (en_route) begin
        cyc <= cyc + 14'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------------------
  // Paramètres des oscillateurs d'essai (le synthétiseur les lira en mémoire)
  // ---------------------------------------------------------------------------------------
  function [23:0] f_inc(input [1:0] p);
    case (p)
      2'd0: f_inc = 24'd139810;   // 400 Hz
      2'd1: f_inc = 24'd209715;   // 600 Hz
      2'd2: f_inc = 24'd314573;   // 900 Hz
      default: f_inc = 24'd419430; // 1 200 Hz
    endcase
  endfunction
  function [3:0] f_w(input [1:0] p);
    case (p)
      2'd0: f_w = 4'd0;
      2'd1: f_w = 4'd5;
      2'd2: f_w = 4'd10;
      default: f_w = 4'd15;
    endcase
  endfunction
  function [15:0] f_gain(input [2:0] o);
    case (o)
      3'd0: f_gain = 16'd40000;
      3'd1: f_gain = 16'd28000;
      3'd2: f_gain = 16'd30000;
      3'd3: f_gain = 16'd30000;
      3'd4: f_gain = 16'd20000;
      3'd5: f_gain = 16'd26000;
      3'd6: f_gain = 16'd24000;
      default: f_gain = 16'd18000;
    endcase
  endfunction

  // ---------------------------------------------------------------------------------------
  // Préparation du créneau suivant, pendant le créneau en cours (16 cycles disponibles)
  // ---------------------------------------------------------------------------------------
  reg  [23:0] phase_osc [0:7];          // phase de chaque oscillateur (en mémoire plus tard)
  wire [9:0]  creneau_s = creneau + 10'd1;
  reg  [2:0]  p_o;  reg p_ok;  reg [23:0] p_inc;  reg [3:0] p_w;  reg [15:0] p_gain;
  reg  [23:0] p_phase;  reg [6:0] p_age, p_age1;
  reg  [15:0] p_e0, p_e1;               // enveloppe au début et à la fin du bloc
  reg  [15:0] p_a0, p_a1;               // amplitudes (gain × enveloppe)
  reg  signed [16:0] p_damp;            // pas d'amplitude par échantillon (en 1/16)
  wire [15:0] env0, env1;
  wire signed [33:0] m0, m1;

  sonde_rom_env u_env0 (.a(p_age),  .v(env0));
  sonde_rom_env u_env1 (.a(p_age1), .v(env1));
  mult_2etages #(.LA(17), .LB(17)) u_m0 (.clk(clk), .a({1'b0, p_gain}), .b({1'b0, p_e0}), .p(m0));
  mult_2etages #(.LA(17), .LB(17)) u_m1 (.clk(clk), .a({1'b0, p_gain}), .b({1'b0, p_e1}), .p(m1));

  integer k;
  always @(posedge clk) begin
    if (!rst_n) begin
      p_o <= 3'd0;  p_ok <= 1'b0;  p_inc <= 24'd0;  p_w <= 4'd0;  p_gain <= 16'd0;
      p_phase <= 24'd0;  p_age <= 7'd0;  p_age1 <= 7'd0;  p_e0 <= 16'd0;  p_e1 <= 16'd0;
      p_a0 <= 16'd0;  p_a1 <= 16'd0;  p_damp <= 17'sd0;
    end else case (ech)
      4'd0: begin
        p_o     <= creneau_s[2:0];
        p_ok    <= (creneau_s[9:3] == 7'd0);
        p_inc   <= f_inc(creneau_s[2:1]);
        p_w     <= f_w(creneau_s[2:1]);
        p_gain  <= (creneau_s[9:3] == 7'd0) ? f_gain(creneau_s[2:0]) : 16'd0;
        p_phase <= phase_osc[creneau_s[2:0]];
        // le créneau 0 du bloc suivant prend l'âge du bloc suivant
        p_age   <= (creneau == 10'd1023) ? ages  : age;
        p_age1  <= (creneau == 10'd1023) ? ages1 : age1;
      end
      4'd1: begin p_e0 <= env0; p_e1 <= env1; end
      // 4'd2 à 4'd3 : multiplications en 2 étages (u_m0, u_m1)
      4'd5: begin p_a0 <= m0[31:16]; p_a1 <= m1[31:16]; end
      4'd6: p_damp <= $signed({1'b0, p_a1}) - $signed({1'b0, p_a0});
      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------------------
  // Étage 0 : phase et amplitude de l'échantillon en cours (boucles d'un cycle)
  // ---------------------------------------------------------------------------------------
  reg  [23:0] th, c_inc;
  reg  [19:0] amp;                       // amplitude, 4 bits après la virgule
  reg  signed [16:0] c_damp;
  reg  [3:0]  c_w;  reg [2:0] c_o;  reg c_ok;
  reg  [9:0]  c_creneau;                 // créneau traité par l'étage 0
  wire [23:0] th_suiv = th + c_inc;

  always @(posedge clk) begin
    if (!rst_n) begin
      th <= 24'd0; c_inc <= 24'd0; amp <= 20'd0; c_damp <= 17'sd0;
      c_w <= 4'd0; c_o <= 3'd0; c_ok <= 1'b0; c_creneau <= 10'd0;
      for (k = 0; k < 8; k = k + 1) phase_osc[k] <= 24'd0;
    end else if (ech == 4'd15) begin
      if (c_ok) phase_osc[c_o] <= th_suiv;     // phase au début du bloc suivant
      th <= p_phase;  c_inc <= p_inc;  amp <= {p_a0, 4'd0};  c_damp <= p_damp;
      c_w <= p_w;  c_o <= p_o;  c_ok <= p_ok;  c_creneau <= creneau_s;
    end else begin
      th  <= th_suiv;
      amp <= amp + {{3{c_damp[16]}}, c_damp};
    end
  end

  // Étiquette qui suit l'échantillon dans les étages : oreille, n° d'échantillon, premier
  // créneau de l'oreille dans le bloc (remise à zéro de l'accumulateur)
  wire [5:0] etiq0 = {c_creneau[9:1] == 9'd0, c_creneau[0], ech};

  // ---------------------------------------------------------------------------------------
  // Étages 1 à 6 : forme d'onde s = sinus(θ) + w · différence(θ)
  // ---------------------------------------------------------------------------------------
  // 1 : position dans le quart d'onde (lue à l'envers aux quadrants 1 et 3)
  reg [7:0] e1_j, e1_fr, e1_kd;  reg e1_neg;  reg [15:0] e1_amp;  reg [3:0] e1_w;  reg [5:0] e1_t;
  wire [15:0] pos = th[22] ? ~th[21:6] : th[21:6];
  always @(posedge clk) begin
    e1_j <= pos[15:8];  e1_fr <= pos[7:0];  e1_neg <= th[23];  e1_kd <= th[23:16];
    e1_amp <= amp[19:4];  e1_w <= c_w;  e1_t <= etiq0;
  end

  // 2 : lecture des tables
  wire [15:0] rq;  wire [7:0] rd;  wire signed [15:0] rdif;
  sonde_rom_q   u_q   (.a(e1_j),  .v(rq));
  sonde_rom_d   u_d   (.a(e1_j),  .v(rd));
  sonde_rom_dif u_dif (.a(e1_kd), .v(rdif));
  reg [15:0] e2_q;  reg [7:0] e2_d, e2_fr;  reg signed [15:0] e2_dif;
  reg e2_neg;  reg [15:0] e2_amp;  reg [3:0] e2_w;  reg [5:0] e2_t;
  always @(posedge clk) begin
    e2_q <= rq;  e2_d <= rd;  e2_dif <= rdif;  e2_fr <= e1_fr;
    e2_neg <= e1_neg;  e2_amp <= e1_amp;  e2_w <= e1_w;  e2_t <= e1_t;
  end

  // 3 : produits de l'interpolation et du timbre
  reg [15:0] e3_pi;  reg signed [20:0] e3_pw;  reg [15:0] e3_q;
  reg e3_neg;  reg [15:0] e3_amp;  reg [5:0] e3_t;
  always @(posedge clk) begin
    e3_pi <= e2_d * e2_fr;
    e3_pw <= $signed({1'b0, e2_w}) * e2_dif;
    e3_q <= e2_q;  e3_neg <= e2_neg;  e3_amp <= e2_amp;  e3_t <= e2_t;
  end

  // 4 : sinus interpolé (valeur absolue) ; timbre ramené à l'échelle (÷ 16)
  reg [16:0] e4_sabs;  reg signed [16:0] e4_pw;  reg e4_neg;  reg [15:0] e4_amp;  reg [5:0] e4_t;
  always @(posedge clk) begin
    e4_sabs <= {1'b0, e3_q} + {9'd0, e3_pi[15:8]};
    e4_pw   <= e3_pw >>> 4;
    e4_neg <= e3_neg;  e4_amp <= e3_amp;  e4_t <= e3_t;
  end

  // 5 : signe du sinus
  reg signed [17:0] e5_s;  reg signed [16:0] e5_pw;  reg [15:0] e5_amp;  reg [5:0] e5_t;
  always @(posedge clk) begin
    e5_s  <= e4_neg ? -$signed({1'b0, e4_sabs}) : $signed({1'b0, e4_sabs});
    e5_pw <= e4_pw;  e5_amp <= e4_amp;  e5_t <= e4_t;
  end

  // 6 : forme d'onde finale
  reg signed [17:0] e6_s;  reg [15:0] e6_amp;  reg [5:0] e6_t;
  always @(posedge clk) begin
    e6_s <= e5_s + e5_pw;
    e6_amp <= e5_amp;  e6_t <= e5_t;
  end

  // ---------------------------------------------------------------------------------------
  // Étages 7 et 8 : amplitude × forme d'onde (multiplieur en 2 étages)
  // ---------------------------------------------------------------------------------------
  wire signed [34:0] prod;
  mult_2etages #(.LA(17), .LB(18)) u_mp (.clk(clk), .a({1'b0, e6_amp}), .b(e6_s), .p(prod));
  reg [5:0] e7_t, e8_t;
  always @(posedge clk) begin
    e7_t <= e6_t;  e8_t <= e7_t;
  end

  // ---------------------------------------------------------------------------------------
  // Étages 9 et 10 : accumulation (16 accumulateurs par oreille), lecture puis écriture.
  // Un même accumulateur n'est repris que 32 cycles plus tard (même oreille, créneau + 2).
  // ---------------------------------------------------------------------------------------
  reg signed [25:0] acc [0:31];
  reg signed [22:0] e9_c;  reg signed [25:0] e9_acc;  reg [5:0] e9_t;
  always @(posedge clk) begin
    e9_c   <= prod >>> 12;
    e9_acc <= acc[e8_t[4:0]];
    e9_t   <= e8_t;
  end

  reg signed [23:0] sortie [0:31];       // échantillons du bloc précédent
  function signed [23:0] sature(input signed [25:0] x);
    if (x > 26'sd8388607)       sature = 24'sd8388607;
    else if (x < -26'sd8388608) sature = -24'sd8388608;
    else                        sature = x[23:0];
  endfunction
  always @(posedge clk) begin
    if (!rst_n) begin
      for (k = 0; k < 32; k = k + 1) begin
        acc[k]    <= 26'sd0;
        sortie[k] <= 24'sd0;
      end
    end else if (e9_t[5]) begin
      acc[e9_t[4:0]]    <= {{3{e9_c[22]}}, e9_c};   // premier créneau : on repart de zéro
      sortie[e9_t[4:0]] <= sature(e9_acc);         // et le bloc précédent est terminé
    end else begin
      acc[e9_t[4:0]] <= e9_acc + {{3{e9_c[22]}}, e9_c};
    end
  end

  // Échantillon de la trame en cours (lu dans le tampon, une trame avant sa prise par l'I2S)
  always @(posedge clk) begin
    if (!rst_n) begin
      gauche <= 24'sd0;
      droite <= 24'sd0;
    end else begin
      gauche <= sortie[{1'b0, trame}];
      droite <= sortie[{1'b1, trame}];
    end
  end

endmodule

/*
 * Multiplieur signé en 2 étages : b est coupé en deux moitiés, les deux produits partiels
 * sont calculés au 1er étage, additionnés au 2e. Résultat 2 cycles après les opérandes.
 */
module mult_2etages #(
    parameter integer LA = 17,
    parameter integer LB = 17
) (
    input  wire                      clk,
    input  wire signed [LA-1:0]      a,
    input  wire signed [LB-1:0]      b,
    output reg  signed [LA+LB-1:0]   p
);
  localparam integer LBB = LB / 2;            // bits de poids faible de b
  wire signed [LBB:0]      b_bas  = {1'b0, b[LBB-1:0]};
  wire signed [LB-LBB-1:0] b_haut = b[LB-1:LBB];
  reg  signed [LA+LBB:0]      p_bas;
  reg  signed [LA+LB-LBB-1:0] p_haut;
  always @(posedge clk) begin
    p_bas  <= a * b_bas;
    p_haut <= a * b_haut;
    p      <= (p_haut <<< LBB) + p_bas;
  end
endmodule
