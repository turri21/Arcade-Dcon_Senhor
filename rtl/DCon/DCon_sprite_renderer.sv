// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of DCon_MiSTer.

    DCon_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    DCon_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with DCon_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

/*  Sprite renderer Seibu SEI0211.

    Spriteram: 256 entry × 8 byte (4 word) @ 0x08F800-0x08FFFF.

    Format word (formato "comune", non alt_format) da MAME
    src/mame/seibu/sei021x_sei0220_spr.cpp:
      w0 bit 15      = enable (0=skip, 1=draw)
      w0 bit 14      = flip_x
      w0 bit 13      = flip_y
      w0 bit 12..10  = sizex (3-bit, +1) → 1..8 tile larghezza
      w0 bit 9..7    = sizey (3-bit, +1) → 1..8 tile altezza
      w0 bit 6       = ext (extra bit per priority callback)
      w0 bit 5..0    = color (6-bit, color_base = color << 4)
      w1 bit 15..14  = priority code (2-bit, → pri_cb)
      w1 bit 13..0   = tile_code (14-bit)
      w2 bit 8..0    = X (signed 9-bit)
      w3 bit 8..0    = Y (signed 9-bit)

    Tile size 16×16 4bpp = 128 byte/tile = 32 word 16-bit.
    Multi-tile: tile_code += 1 per sub-tile (TODO: ordine x-major o y-major
    da verificare con dump MAME — assunto x-major per ora).

    Priority callback dcon.cpp::pri_cb:
      pri=0 → above FG
      pri=1 → above MG
      pri=2 → above BG
      pri=3 → above Text (= sotto Text)

    Pen 15 = trasparente.

    Architettura:
      - Sprite scan FSM durante linea N: scorre 256 entry, per quelle che
        intersecano linea N+1 (target_y), fetch SDRAM dei tile coperti e
        scrive in line buffer non-attivo.
      - Read side: a hpos legge line buffer attivo, restituisce pen+pri_code.
      - Ping-pong al new_line.

    Worst case: 256 entry × max 8 sizex × 1 fetch/tile = 2048 fetch/linea.
    Realistico: 30 sprite × 4 sizex avg = 120 fetch. Banda OK.

    ─── Ottimizzazioni performance (no logic change) ────────────────────
    Line buffer = 8 bank interleaved da 40×14 (320 pixel totali, lane =
    dx[2:0], riga = dx[8:3]). Permette:
      - SC_DECODE in 1 ciclo invece di 8: tutti gli 8 pixel della mezza-
        riga scritti in parallelo (un write per bank).
      - SC_CLEAR in 40 cicli invece di 320: 8 entry azzerate/ciclo.
    Pre-fetch w0/w3 next entry durante decode (BRAM spriteram libero
    mentre decodifichiamo) → -3 cicli per entry.
*/

module DCon_sprite_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	input  wire  [9:0] hpos,        // 0..319 logico
	input  wire  [8:0] vpos,        // 0..223 logico
	input  wire        de,
	input  wire        layer_en,
	input  wire        new_line,

	// OSD offset (signed 10-bit, range -32..+31)
	input  wire signed [9:0] xoff,
	input  wire signed [9:0] yoff,

	// Sprite RAM read port (dual-port lato B)
	output reg   [9:0] spr_addr,    // 1024 word total (256 entry × 4 word)
	input  wire [15:0] spr_data,

	// SDRAM tile fetch via arbiter (client r3, kind=3, no cache)
	output reg         rom_req,
	output reg  [23:0] rom_addr,
	input  wire [31:0] rom_data,
	input  wire        rom_valid,

	// Output pixel (combinatoriale: niente latency latch)
	output wire        opaque,
	output wire [10:0] pen_index,
	output wire  [1:0] pri_code
);

	// ─── Line buffer ping-pong (8 bank interleaved per parallel write) ──
	// Layout 14-bit: [13:8]=color, [7:6]=pri_code, [5:4]=00, [3:0]=pen
	// Bank b contiene i pixel con dx[2:0]==b → indicizzato da dx[8:3] (0..39).
	// Permette 8 write paralleli in 1 ciclo (decode 8 pixel/ciclo) e clear
	// in 40 cicli invece di 320. Vista esterna: identica al singolo array.
	localparam [13:0] LB_EMPTY = 14'h003F;  // color=0, pri=0, pen=15 (trasparente)
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b0 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b1 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b2 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b3 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b4 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b5 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b6 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf0_b7 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b0 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b1 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b2 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b3 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b4 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b5 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b6 [0:39];
	(* ramstyle = "M10K,no_rw_check" *) reg [13:0] linebuf1_b7 [0:39];
	reg        active_buf;

	// ─── Sprite scan FSM ─────────────────────────────────────────────────────
	// Stati: IDLE → CLEAR (azzera buffer non-attivo a pen=15) → RW0..3 (legge
	// 4 word di entry) → CHECK → ROM_REQ/W → DECODE → NEXT_TX/E → DONE.
	localparam SC_IDLE        = 4'd0;
	localparam SC_CLEAR       = 4'd1;
	localparam SC_RW0         = 4'd2;
	localparam SC_RW1         = 4'd3;
	localparam SC_RW2         = 4'd4;
	localparam SC_RW3         = 4'd5;
	localparam SC_CHECK       = 4'd6;
	localparam SC_CHECK2      = 4'd7;
	localparam SC_ROM_REQ     = 4'd8;
	localparam SC_ROM_W       = 4'd9;
	localparam SC_DECODE      = 4'd10;
	localparam SC_NEXT_TX     = 4'd11;
	localparam SC_NEXT_E      = 4'd12;
	localparam SC_DONE        = 4'd13;
	localparam SC_CHECK2_W2   = 4'd14;
	localparam SC_DECODE_WR   = 4'd15;   // pipeline: SC_DECODE calcola+latch
	                                     // bank_we/row/wd, SC_DECODE_WR scrive ai bank

	reg [3:0] sc_state;
	reg [7:0] entry_idx;       // 0..255
	reg [5:0] clear_idx;       // 0..39 per clear buffer (8 lane in parallelo)
	reg [15:0] sp_w0, sp_w1, sp_w2, sp_w3;
	reg        pf_side;        // 0=metà sx tile (col 0..7), 1=metà dx (col 8..15)

	// Decoded fields
	wire        sp_enable = sp_w0[15];
	wire        sp_flipx  = sp_w0[14];
	wire        sp_flipy  = sp_w0[13];
	wire  [2:0] sp_sizex  = sp_w0[12:10];      // +1 → 1..8 tile
	wire  [2:0] sp_sizey  = sp_w0[9:7];        // +1
	wire  [5:0] sp_color  = sp_w0[5:0];
	wire  [1:0] sp_pri    = sp_w1[15:14];
	wire [13:0] sp_code   = sp_w1[13:0];
	// SEI0211 get_coordinate (MAME sei021x_sei0220_spr.h):
	//   coord &= 0x1ff;
	//   return (coord >= 0x180) ? coord - 0x200 : coord;
	// Range effettivo: -128..+383 (positivi 0..0x17F, negativi 0x180..0x1FF).
	// Y: lo sprite ha direzione opposta agli altri layer → -16 (verificato HW)
	wire [8:0] sp_xraw = sp_w2[8:0];
	wire [8:0] sp_yraw = sp_w3[8:0];
	wire signed [10:0] sp_x_raw = (sp_xraw >= 9'h180) ? ({2'b00, sp_xraw} - 11'h200) : {2'b00, sp_xraw};
	wire signed [10:0] sp_y_raw = (sp_yraw >= 9'h180) ? ({2'b00, sp_yraw} - 11'h200) : {2'b00, sp_yraw};
	// Hardcode pixel-perfect MAME (valori netti commit 28adc3a, OSD a 0):
	//   X = sp_x_raw + 1
	//   Y = sp_y_raw + 0   (era +16 OSD - 16 HW = 0 netto)
	// xoff/yoff porte conservate per compat ma non più cablate al top.
	wire signed [10:0] sp_x = sp_x_raw + {xoff[9], xoff} + 11'sd1;
	wire signed [10:0] sp_y = sp_y_raw + {yoff[9], yoff};

	wire [3:0] sp_w  = {1'b0, sp_sizex} + 4'd1;    // 1..8
	wire [3:0] sp_h  = {1'b0, sp_sizey} + 4'd1;    // 1..8

	// Target Y per la linea che stiamo prefetchando (= linea corrente + 1, wrap)
	wire [8:0] target_y = (vpos == 9'd223) ? 9'd0 : (vpos + 9'd1);

	// Sprite intersect check: target_y in [sp_y, sp_y + sp_h*16)
	wire signed [10:0] dy_top = {2'b00, target_y} - sp_y;
	wire        in_y     = (dy_top >= 0) && (dy_top < {3'd0, sp_h, 4'd0});  // sp_h*16
	wire  [3:0] tile_y_in = dy_top[7:4];   // tile row 0..7 dentro sprite
	wire  [3:0] row_in    = dy_top[3:0];   // row dentro tile 0..15
	// flip Y
	wire  [3:0] eff_tile_y = sp_flipy ? (sp_h - 4'd1 - tile_y_in) : tile_y_in;
	wire  [3:0] eff_row    = sp_flipy ? (4'd15 - row_in)          : row_in;

	// Iteratore tile_x
	reg  [3:0] tile_x_pf;
	reg [31:0] pf_rom_data;
	wire  [3:0] eff_tile_x = sp_flipx ? (sp_w - 4'd1 - tile_x_pf) : tile_x_pf;

	// Tile code finale Y-MAJOR (MAME draw_internal: ax=outer, ay=inner, code++):
	//   sub_index = ax*sizey + ay  →  cur_tile = code + eff_tile_x*sp_h + eff_tile_y
	wire [13:0] cur_tile = sp_code + ({10'd0, eff_tile_x} * {10'd0, sp_h}) + {10'd0, eff_tile_y};

	// new_line gating
	wire vpos_visible = (vpos < 9'd224);
	wire gated_new_line = new_line & vpos_visible;

	// ─── Parallel decode (8 pixel della mezza-riga in un colpo) ──────────────
	// Estraggo gli 8 pen della mezza-riga in combinatoria, e in SC_DECODE
	// scrivo tutti gli 8 bank in parallelo (1 ciclo invece di 8).
	wire [7:0] dec_byte0 = pf_rom_data[31:24];
	wire [7:0] dec_byte1 = pf_rom_data[23:16];
	wire [7:0] dec_byte2 = pf_rom_data[15:8];
	wire [7:0] dec_byte3 = pf_rom_data[7:0];

	// Per ogni step k (0..7), pf_rom_data fornisce un pen 4-bit:
	//   step k<4: byte_lo=byte0, byte_hi=byte1, sub = 3 - k[1:0]
	//   step k>=4: byte_lo=byte2, byte_hi=byte3, sub = 3 - k[1:0]
	// pen[3]=byte_lo[7-sub], pen[2]=byte_lo[3-sub], pen[1]=byte_hi[7-sub], pen[0]=byte_hi[3-sub]
	function [3:0] pen_at;
		input integer k;
		reg [7:0] blo, bhi;
		reg [2:0] sub;
		begin
			if (k < 4) begin blo = dec_byte0; bhi = dec_byte1; end
			else       begin blo = dec_byte2; bhi = dec_byte3; end
			sub = 3'd3 - k[1:0];
			pen_at[3] = blo[7 - sub];
			pen_at[2] = blo[3 - sub];
			pen_at[1] = bhi[7 - sub];
			pen_at[0] = bhi[3 - sub];
		end
	endfunction

	wire [3:0] pen0 = pen_at(0);
	wire [3:0] pen1 = pen_at(1);
	wire [3:0] pen2 = pen_at(2);
	wire [3:0] pen3 = pen_at(3);
	wire [3:0] pen4 = pen_at(4);
	wire [3:0] pen5 = pen_at(5);
	wire [3:0] pen6 = pen_at(6);
	wire [3:0] pen7 = pen_at(7);

	// Posizione X del primo pixel della mezza-riga sullo schermo.
	// Logica originale (SC_DECODE): eff_col = sp_flipx ? (15 - {pf_side,step})
	//                                                   : {pf_side,step}
	//                               dx = sp_x + tile_x_pf*16 + eff_col
	// Calcolo dx per ogni step in parallelo.
	wire signed [10:0] base_x = sp_x + ({6'd0, tile_x_pf, 4'd0});

	function signed [10:0] dx_at;
		input integer k;
		reg [4:0] eff_col;
		begin
			eff_col = sp_flipx ? (5'd15 - {pf_side, k[2:0]})
			                   : {pf_side, k[2:0]};
			dx_at = base_x + {6'd0, eff_col};
		end
	endfunction

	wire signed [10:0] dx0 = dx_at(0);
	wire signed [10:0] dx1 = dx_at(1);
	wire signed [10:0] dx2 = dx_at(2);
	wire signed [10:0] dx3 = dx_at(3);
	wire signed [10:0] dx4 = dx_at(4);
	wire signed [10:0] dx5 = dx_at(5);
	wire signed [10:0] dx6 = dx_at(6);
	wire signed [10:0] dx7 = dx_at(7);

	// Mask "scrivibile": pen != 15 e dx in [0,320)
	wire wr0 = (pen0 != 4'd15) && (dx0 >= 0) && (dx0 < 320);
	wire wr1 = (pen1 != 4'd15) && (dx1 >= 0) && (dx1 < 320);
	wire wr2 = (pen2 != 4'd15) && (dx2 >= 0) && (dx2 < 320);
	wire wr3 = (pen3 != 4'd15) && (dx3 >= 0) && (dx3 < 320);
	wire wr4 = (pen4 != 4'd15) && (dx4 >= 0) && (dx4 < 320);
	wire wr5 = (pen5 != 4'd15) && (dx5 >= 0) && (dx5 < 320);
	wire wr6 = (pen6 != 4'd15) && (dx6 >= 0) && (dx6 < 320);
	wire wr7 = (pen7 != 4'd15) && (dx7 >= 0) && (dx7 < 320);

	// Bank di destinazione per ogni step: dx[2:0]. Lane address: dx[8:3].
	wire [2:0] ln0 = dx0[2:0];   wire [5:0] rw0 = dx0[8:3];
	wire [2:0] ln1 = dx1[2:0];   wire [5:0] rw1_a = dx1[8:3];
	wire [2:0] ln2 = dx2[2:0];   wire [5:0] rw2_a = dx2[8:3];
	wire [2:0] ln3 = dx3[2:0];   wire [5:0] rw3_a = dx3[8:3];
	wire [2:0] ln4 = dx4[2:0];   wire [5:0] rw4_a = dx4[8:3];
	wire [2:0] ln5 = dx5[2:0];   wire [5:0] rw5_a = dx5[8:3];
	wire [2:0] ln6 = dx6[2:0];   wire [5:0] rw6_a = dx6[8:3];
	wire [2:0] ln7 = dx7[2:0];   wire [5:0] rw7_a = dx7[8:3];

	// Dato da scrivere per ogni step (formato linebuf 14-bit)
	wire [13:0] wd0 = {sp_color, sp_pri, 2'd0, pen0};
	wire [13:0] wd1 = {sp_color, sp_pri, 2'd0, pen1};
	wire [13:0] wd2 = {sp_color, sp_pri, 2'd0, pen2};
	wire [13:0] wd3 = {sp_color, sp_pri, 2'd0, pen3};
	wire [13:0] wd4 = {sp_color, sp_pri, 2'd0, pen4};
	wire [13:0] wd5 = {sp_color, sp_pri, 2'd0, pen5};
	wire [13:0] wd6 = {sp_color, sp_pri, 2'd0, pen6};
	wire [13:0] wd7 = {sp_color, sp_pri, 2'd0, pen7};

	// Per ogni bank b, seleziono lo step che ha ln==b (al massimo uno per
	// step di pixel non sovrapposti — ma flipX/sizex generano dx unici
	// nella stessa mezza-riga, quindi ogni bank al più 1 step la scrive).
	// Se più step targettassero lo stesso bank (caso patologico off-screen),
	// vince lo step con indice più alto (priority encoder reverse). Non
	// influenza pixel visibili perché solo uno è in [0,320).
	reg        bank_we [0:7];
	reg [5:0]  bank_row [0:7];
	reg [13:0] bank_wd  [0:7];

	// Pipeline stage: registri dopo bank_select (catena combinatoria lunga
	// = priority encoder 8-vie con cascata di 28 confronti ln_X==ln_Y).
	// Scrittura ai bank avviene nel ciclo SC_DECODE_WR usando questi reg,
	// così il path critico si spezza in 2 stadi. Costo: +1 ciclo per ogni
	// half-tile (SC_DECODE → SC_DECODE_WR → SC_NEXT_TX), invisibile esterno.
	reg        q_bank_we [0:7];
	reg [5:0]  q_bank_row [0:7];
	reg [13:0] q_bank_wd  [0:7];

	always @(*) begin : bank_select
		integer b;
		for (b = 0; b < 8; b = b + 1) begin
			bank_we[b]  = 1'b0;
			bank_row[b] = 6'd0;
			bank_wd[b]  = 14'd0;
		end
		// Priority encoder: step 0 vince in caso di collisione (raro).
		if (wr0) begin bank_we[ln0] = 1'b1; bank_row[ln0] = rw0;   bank_wd[ln0] = wd0; end
		if (wr1 && !(wr0 && ln0==ln1)) begin bank_we[ln1] = 1'b1; bank_row[ln1] = rw1_a; bank_wd[ln1] = wd1; end
		if (wr2 && !((wr0 && ln0==ln2) || (wr1 && ln1==ln2))) begin bank_we[ln2] = 1'b1; bank_row[ln2] = rw2_a; bank_wd[ln2] = wd2; end
		if (wr3 && !((wr0 && ln0==ln3) || (wr1 && ln1==ln3) || (wr2 && ln2==ln3))) begin bank_we[ln3] = 1'b1; bank_row[ln3] = rw3_a; bank_wd[ln3] = wd3; end
		if (wr4 && !((wr0 && ln0==ln4) || (wr1 && ln1==ln4) || (wr2 && ln2==ln4) || (wr3 && ln3==ln4))) begin bank_we[ln4] = 1'b1; bank_row[ln4] = rw4_a; bank_wd[ln4] = wd4; end
		if (wr5 && !((wr0 && ln0==ln5) || (wr1 && ln1==ln5) || (wr2 && ln2==ln5) || (wr3 && ln3==ln5) || (wr4 && ln4==ln5))) begin bank_we[ln5] = 1'b1; bank_row[ln5] = rw5_a; bank_wd[ln5] = wd5; end
		if (wr6 && !((wr0 && ln0==ln6) || (wr1 && ln1==ln6) || (wr2 && ln2==ln6) || (wr3 && ln3==ln6) || (wr4 && ln4==ln6) || (wr5 && ln5==ln6))) begin bank_we[ln6] = 1'b1; bank_row[ln6] = rw6_a; bank_wd[ln6] = wd6; end
		if (wr7 && !((wr0 && ln0==ln7) || (wr1 && ln1==ln7) || (wr2 && ln2==ln7) || (wr3 && ln3==ln7) || (wr4 && ln4==ln7) || (wr5 && ln5==ln7) || (wr6 && ln6==ln7))) begin bank_we[ln7] = 1'b1; bank_row[ln7] = rw7_a; bank_wd[ln7] = wd7; end
	end

	always @(posedge clk) begin
		if (reset) begin
			sc_state    <= SC_IDLE;
			entry_idx   <= 8'd255;
			tile_x_pf   <= 4'd0;
			rom_req     <= 1'b0;
			spr_addr    <= 10'd0;
			active_buf  <= 1'b0;
			clear_idx   <= 6'd0;
		end else begin
			case (sc_state)
				SC_IDLE: begin
					if (gated_new_line) begin
						active_buf <= ~active_buf;
						// First-win: scan da entry 255 → 0, così entry 0 (scritta
						// per ultima) sovrascrive le altre = entry 0 sopra in priorità
						entry_idx  <= 8'd255;
						tile_x_pf  <= 4'd0;
						clear_idx  <= 6'd0;
						sc_state   <= SC_CLEAR;
					end
				end

				// CLEAR: solo state/counter qui; i write effettivi avvengono
				// nell'unified write block sotto (per consentire M10K inference).
				SC_CLEAR: begin
					if (clear_idx == 6'd39) begin
						clear_idx <= 6'd0;
						spr_addr  <= {entry_idx, 2'd0};   // primo scan = entry 255
						sc_state  <= SC_RW0;
					end else begin
						clear_idx <= clear_idx + 6'd1;
					end
				end

				// OTTIMIZZAZIONE early-skip (pattern BloodBros 855c14e):
				// leggo w0 e w3 PRIMA (servono per enable + in_y), e leggo w1/w2
				// SOLO se sprite visibile. Risparmio 2 cicli BRAM sulla maggioranza
				// dei 256 slot disabled/off-screen.
				SC_RW0: begin
					spr_addr <= {entry_idx, 2'd3};   // skip w1/w2, leggi w3 direttamente
					sc_state <= SC_RW1;
				end
				SC_RW1: begin
					sp_w0    <= spr_data;            // w0 valido
					sc_state <= SC_RW3;              // prossimo ciclo arriva w3
				end
				SC_RW3: begin
					sp_w3    <= spr_data;            // w3 valido (sp_y_raw)
					sc_state <= SC_CHECK;
				end

				// SC_CHECK: w0 e w3 latched. Valuto enable && in_y. Se non visibile,
				// salto direttamente a SC_NEXT_E senza leggere w1/w2.
				SC_CHECK: begin
					if (sp_enable && in_y && layer_en) begin
						// Sprite visibile: leggi w1 (tile code) ora.
						spr_addr <= {entry_idx, 2'd1};
						sc_state <= SC_RW2;
					end else begin
						// Early skip: non leggo w1/w2 affatto.
						sc_state <= SC_NEXT_E;
					end
				end

				// Sprite visibile: leggo w1 e w2 (richiesti per decode tile/color/x).
				SC_RW2: begin
					// w1 in flight, emetto w2
					spr_addr <= {entry_idx, 2'd2};
					sc_state <= SC_CHECK2;
				end

				SC_CHECK2: begin
					sp_w1    <= spr_data;            // w1 valido (latency 1)
					sc_state <= SC_CHECK2_W2;
				end

				// Stato extra per latch w2 (era SC_CHECK2 nel flow vecchio).
				SC_CHECK2_W2: begin
					sp_w2    <= spr_data;
					tile_x_pf <= 4'd0;
					pf_side   <= 1'b0;
					sc_state  <= SC_ROM_REQ;
				end

				SC_ROM_REQ: begin
					// Sprite tile addr in SDRAM region (byte_offset relativo):
					// tile_code * 128 (32 word) + (pf_side ? 64 byte : 0) + eff_row * 4
					rom_addr <= ({4'd0, cur_tile, 7'd0})        // tile*128
					           + (pf_side ? 24'd64 : 24'd0)     // metà dx tile
					           + ({18'd0, eff_row, 2'd0});       // row*4
					rom_req  <= 1'b1;
					sc_state <= SC_ROM_W;
				end

				SC_ROM_W: begin
					if (rom_valid) begin
						pf_rom_data <= rom_data;
						rom_req     <= 1'b0;
						sc_state    <= SC_DECODE;
					end
				end

				// DECODE PIPELINE STAGE 1: latch del risultato di bank_select
				// nei registri q_bank_we/row/wd (sotto). Nessun write ai bank qui.
				SC_DECODE: begin
					sc_state <= SC_DECODE_WR;
				end

				// DECODE PIPELINE STAGE 2: write paralleli ai bank usando
				// i registri q_bank_*. Path corto: solo 8 if su reg.
				SC_DECODE_WR: begin
					sc_state <= SC_NEXT_TX;
				end

				SC_NEXT_TX: begin
					if (pf_side == 1'b0) begin
						// Appena finito metà sx → fai metà dx dello stesso tile
						pf_side  <= 1'b1;
						sc_state <= SC_ROM_REQ;
					end else begin
						// Finito anche metà dx → passa al prossimo tile_x o entry
						pf_side <= 1'b0;
						if (tile_x_pf == sp_w - 4'd1) begin
							sc_state <= SC_NEXT_E;
						end else begin
							tile_x_pf <= tile_x_pf + 4'd1;
							sc_state  <= SC_ROM_REQ;
						end
					end
				end

				SC_NEXT_E: begin
					// Scan decrescente: 255 → 254 → ... → 0, poi DONE
					if (entry_idx == 8'd0) begin
						sc_state <= SC_DONE;
					end else begin
						entry_idx <= entry_idx - 8'd1;
						spr_addr  <= {entry_idx - 8'd1, 2'd0};
						sc_state  <= SC_RW0;
					end
				end

				SC_DONE: begin
					if (gated_new_line) begin
						active_buf <= ~active_buf;
						entry_idx  <= 8'd255;       // first-win scan
						tile_x_pf  <= 4'd0;
						clear_idx  <= 6'd0;
						sc_state   <= SC_CLEAR;
					end
				end

				default: sc_state <= SC_IDLE;
			endcase
		end
	end

	// ─── Pipeline stage 1: latch bank_select in registri durante SC_DECODE ──
	// Spezza il path critico (priority encoder 8-vie cascaded, fanout 203).
	// Nessuna logica visibile esternamente: l'unica differenza è che la
	// FSM impiega 1 ciclo in più per half-tile (SC_DECODE → SC_DECODE_WR).
	always @(posedge clk) begin
		if (sc_state == SC_DECODE) begin
			q_bank_we[0]  <= bank_we[0];  q_bank_row[0] <= bank_row[0];  q_bank_wd[0] <= bank_wd[0];
			q_bank_we[1]  <= bank_we[1];  q_bank_row[1] <= bank_row[1];  q_bank_wd[1] <= bank_wd[1];
			q_bank_we[2]  <= bank_we[2];  q_bank_row[2] <= bank_row[2];  q_bank_wd[2] <= bank_wd[2];
			q_bank_we[3]  <= bank_we[3];  q_bank_row[3] <= bank_row[3];  q_bank_wd[3] <= bank_wd[3];
			q_bank_we[4]  <= bank_we[4];  q_bank_row[4] <= bank_row[4];  q_bank_wd[4] <= bank_wd[4];
			q_bank_we[5]  <= bank_we[5];  q_bank_row[5] <= bank_row[5];  q_bank_wd[5] <= bank_wd[5];
			q_bank_we[6]  <= bank_we[6];  q_bank_row[6] <= bank_row[6];  q_bank_wd[6] <= bank_wd[6];
			q_bank_we[7]  <= bank_we[7];  q_bank_row[7] <= bank_row[7];  q_bank_wd[7] <= bank_wd[7];
		end
	end

	// ─── Unified write block per bank (1 write port logico → M10K) ──────────
	// Per ogni banco: mux address/data tra CLEAR e DECODE_WR. Quartus vede
	// 1 unico write port → inferisce M10K (Simple Dual Port).
	// Buffer 1 = scrivibile quando active_buf=0 (clear OR decode).
	// Buffer 0 = scrivibile quando active_buf=1.
	wire wr1_clear  = (sc_state == SC_CLEAR)     && (active_buf == 1'b0);
	wire wr1_decode = (sc_state == SC_DECODE_WR) && (active_buf == 1'b0);
	wire wr0_clear  = (sc_state == SC_CLEAR)     && (active_buf == 1'b1);
	wire wr0_decode = (sc_state == SC_DECODE_WR) && (active_buf == 1'b1);

	wire        wr1_we [0:7];
	wire [5:0]  wr1_a  [0:7];
	wire [13:0] wr1_d  [0:7];
	wire        wr0_we [0:7];
	wire [5:0]  wr0_a  [0:7];
	wire [13:0] wr0_d  [0:7];

	genvar gb;
	generate
		for (gb = 0; gb < 8; gb = gb + 1) begin : gen_wr_mux
			assign wr1_we[gb] = wr1_clear | (wr1_decode & q_bank_we[gb]);
			assign wr1_a[gb]  = wr1_clear ? clear_idx : q_bank_row[gb];
			assign wr1_d[gb]  = wr1_clear ? LB_EMPTY  : q_bank_wd[gb];
			assign wr0_we[gb] = wr0_clear | (wr0_decode & q_bank_we[gb]);
			assign wr0_a[gb]  = wr0_clear ? clear_idx : q_bank_row[gb];
			assign wr0_d[gb]  = wr0_clear ? LB_EMPTY  : q_bank_wd[gb];
		end
	endgenerate

	always @(posedge clk) begin
		if (wr1_we[0]) linebuf1_b0[wr1_a[0]] <= wr1_d[0];
		if (wr1_we[1]) linebuf1_b1[wr1_a[1]] <= wr1_d[1];
		if (wr1_we[2]) linebuf1_b2[wr1_a[2]] <= wr1_d[2];
		if (wr1_we[3]) linebuf1_b3[wr1_a[3]] <= wr1_d[3];
		if (wr1_we[4]) linebuf1_b4[wr1_a[4]] <= wr1_d[4];
		if (wr1_we[5]) linebuf1_b5[wr1_a[5]] <= wr1_d[5];
		if (wr1_we[6]) linebuf1_b6[wr1_a[6]] <= wr1_d[6];
		if (wr1_we[7]) linebuf1_b7[wr1_a[7]] <= wr1_d[7];
		if (wr0_we[0]) linebuf0_b0[wr0_a[0]] <= wr0_d[0];
		if (wr0_we[1]) linebuf0_b1[wr0_a[1]] <= wr0_d[1];
		if (wr0_we[2]) linebuf0_b2[wr0_a[2]] <= wr0_d[2];
		if (wr0_we[3]) linebuf0_b3[wr0_a[3]] <= wr0_d[3];
		if (wr0_we[4]) linebuf0_b4[wr0_a[4]] <= wr0_d[4];
		if (wr0_we[5]) linebuf0_b5[wr0_a[5]] <= wr0_d[5];
		if (wr0_we[6]) linebuf0_b6[wr0_a[6]] <= wr0_d[6];
		if (wr0_we[7]) linebuf0_b7[wr0_a[7]] <= wr0_d[7];
	end

	// ─── Read side sincrono (M10K-compatible) ────────────────────────────────
	// Prefetch a hpos+1 enabled da ce_pix: ad ogni ce_pix tick (=avanzamento
	// pixel) leggo dal linebuf l'indirizzo hpos+1. Il valore è disponibile
	// al ce_pix tick successivo (quando hpos diventa hpos_prev+1), quindi
	// allineato col pixel corrente. Tra ce_pix tick i registri restano fermi.
	// rd_lane_d e active_buf_d ritardati di 1 ce_pix per coerenza col mux.
	wire [9:0] hpos_pre = hpos + 10'd1;
	wire [2:0] pre_lane = hpos_pre[2:0];
	wire [5:0] pre_row  = hpos_pre[8:3];

	reg [13:0] rdq0_b0, rdq0_b1, rdq0_b2, rdq0_b3, rdq0_b4, rdq0_b5, rdq0_b6, rdq0_b7;
	reg [13:0] rdq1_b0, rdq1_b1, rdq1_b2, rdq1_b3, rdq1_b4, rdq1_b5, rdq1_b6, rdq1_b7;
	reg [2:0]  rd_lane_d;
	reg        active_buf_d;
	always @(posedge clk) begin
		if (ce_pix) begin
			rdq0_b0 <= linebuf0_b0[pre_row];
			rdq0_b1 <= linebuf0_b1[pre_row];
			rdq0_b2 <= linebuf0_b2[pre_row];
			rdq0_b3 <= linebuf0_b3[pre_row];
			rdq0_b4 <= linebuf0_b4[pre_row];
			rdq0_b5 <= linebuf0_b5[pre_row];
			rdq0_b6 <= linebuf0_b6[pre_row];
			rdq0_b7 <= linebuf0_b7[pre_row];
			rdq1_b0 <= linebuf1_b0[pre_row];
			rdq1_b1 <= linebuf1_b1[pre_row];
			rdq1_b2 <= linebuf1_b2[pre_row];
			rdq1_b3 <= linebuf1_b3[pre_row];
			rdq1_b4 <= linebuf1_b4[pre_row];
			rdq1_b5 <= linebuf1_b5[pre_row];
			rdq1_b6 <= linebuf1_b6[pre_row];
			rdq1_b7 <= linebuf1_b7[pre_row];
			rd_lane_d    <= pre_lane;
			active_buf_d <= active_buf;
		end
	end

	reg [13:0] read_data;
	always @(*) begin
		if (active_buf_d) begin
			case (rd_lane_d)
				3'd0: read_data = rdq1_b0;
				3'd1: read_data = rdq1_b1;
				3'd2: read_data = rdq1_b2;
				3'd3: read_data = rdq1_b3;
				3'd4: read_data = rdq1_b4;
				3'd5: read_data = rdq1_b5;
				3'd6: read_data = rdq1_b6;
				3'd7: read_data = rdq1_b7;
			endcase
		end else begin
			case (rd_lane_d)
				3'd0: read_data = rdq0_b0;
				3'd1: read_data = rdq0_b1;
				3'd2: read_data = rdq0_b2;
				3'd3: read_data = rdq0_b3;
				3'd4: read_data = rdq0_b4;
				3'd5: read_data = rdq0_b5;
				3'd6: read_data = rdq0_b6;
				3'd7: read_data = rdq0_b7;
			endcase
		end
	end

	wire  [3:0] read_pen   = read_data[3:0];
	wire  [1:0] read_pri   = read_data[7:6];
	wire  [5:0] read_color = read_data[13:8];

	wire pixel_active = de & layer_en & (hpos < 10'd320) & (read_pen != 4'd15);
	assign opaque    = pixel_active;
	assign pen_index = pixel_active ? {1'b0, read_color, read_pen} : 11'd0;
	assign pri_code  = pixel_active ? read_pri : 2'd0;

endmodule
