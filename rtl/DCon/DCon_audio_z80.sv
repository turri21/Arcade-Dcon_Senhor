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

/*  Audio subsystem Seibu D-Con (Z80 + YM3812 + OKI6295)

    Spec da MAME (reference/mame_seibu/seibusound.cpp + dcon.cpp:dcon):
      - Z80 @ 4.000000 MHz
      - YM3812 (jtopl2) @ 4.000000 MHz
      - OKI M6295 (jt6295) @ 1.320000 MHz, PIN7=LOW

    Z80 memory map (seibu_sound_map):
      0x0000-0x1FFF  ROM fissa 8KB
      0x2000-0x27FF  RAM 2KB
      0x4000         pending_w (sound→main pending)
      0x4001         irq_clear_w (RST18 EOI)
      0x4002         rst10_ack_w (RST10 EOI)
      0x4003         rst18_ack_w (RST18 EOI)
      0x4007         bank_w (Z80 ROM bank, 1 bit)
      0x4008-0x4009  YM3812 r/w (addr/data, 1 bit selector)
      0x4010-0x4011  soundlatch_r (main→sub latch byte 0/1)
      0x4012         main_data_pending_r (main2sub pending flag)
      0x4013         coin_r (legge coin/start input HW)
      0x4018-0x4019  main_data_w (sub→main latch byte 0/1)
      0x401B         coin_w (counter, ignorato in MiSTer)
      0x6000         OKI M6295 r/w
      0x8000-0xFFFF  ROM bank 32KB

    Main↔sub comm @ 0xA0000-0xA000D (mappato in main_top.sv):
      offset 0/1: main_w → m_main2sub[0/1]
      offset 2/3: main_r → m_sub2main[0/1]
      offset 4:   main_w → assert RST18 IRQ to Z80
      offset 5:   main_r → main2sub_pending bit0  (D-Con: no sdgndmps override)
      offset 6:   main_w → set pending flags (mirror)

    IRQ Z80 (IM0):
      RST10 (vector 0xD7) ← YM3812 IRQ (fm_irqhandler)
      RST18 (vector 0xDF) ← main RST18_ASSERT
      Priorità: RST18 > RST10 (im0_vector_cb)
*/

module DCon_audio_z80 (
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,

	// ROM download (ioctl)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,

	// Sound comm bus dal main 68k (mappato a 0xA0000-0xA000D)
	input  wire        snd_cs,
	input  wire  [3:1] snd_addr,
	input  wire        snd_wr,
	input  wire        snd_rd,
	input  wire [15:0] snd_wdata,
	output wire [15:0] snd_rdata,
	input  wire        snd_nmi_n,
	input  wire        snd_reset_in,

	// HW input coin (lette dal Z80 a 0x4013)
	input  wire  [7:0] coin_input,

	// OKI ADPCM ROM bridge (128KB SDRAM, port 3) — DCon ha 128KB pcm
	output wire [17:0] oki_rom_addr,
	input  wire  [7:0] oki_rom_data,
	input  wire        oki_rom_ok,

	// Volumi OSD (Q4.4: 16 = 100%, 32 = 200%, 0 = mute)
	input  wire  [5:0] fm_vol_q44,
	input  wire  [5:0] oki_vol_q44,

	// Audio output stereo 16-bit signed (YM3812 mono → duplicato L/R)
	output reg signed [15:0] audio_l,
	output reg signed [15:0] audio_r
);

	// ─── Clock enable: clk_sys (96 MHz) → Z80/YM 4 MHz, OKI 1.32 MHz ─────────
	// Z80/YM: 96/4 = 24 esatto → div 24, target 4.000 MHz (MAME dcon.cpp:541)
	// OKI: 96/1.32 = 72.73 → div 73, target 1.315 MHz (errore 0.4%, accettabile)
	reg [4:0] cen_z80_cnt;
	reg       cen_z80;
	always @(posedge clk) begin
		if (reset) begin
			cen_z80_cnt <= 5'd0;
			cen_z80     <= 1'b0;
		end else if (cen_z80_cnt == 5'd23) begin
			cen_z80_cnt <= 5'd0;
			cen_z80     <= 1'b1;
		end else begin
			cen_z80_cnt <= cen_z80_cnt + 5'd1;
			cen_z80     <= 1'b0;
		end
	end

	reg [6:0] cen_oki_cnt;
	reg       cen_oki;
	always @(posedge clk) begin
		if (reset) begin
			cen_oki_cnt <= 7'd0;
			cen_oki     <= 1'b0;
		end else if (cen_oki_cnt == 7'd72) begin
			cen_oki_cnt <= 7'd0;
			cen_oki     <= 1'b1;
		end else begin
			cen_oki_cnt <= cen_oki_cnt + 7'd1;
			cen_oki     <= 1'b0;
		end
	end

	// Pause gating (pattern Darius2: cen & ~pause)
	wire cen_z80_g = cen_z80 & ~pause;
	wire cen_oki_g = cen_oki & ~pause;

	// ─── Z80 signals ─────────────────────────────────────────────────────────
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_din;
	wire        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_m1_n;
	wire        z80_int_n;
	wire        z80_busak_n, z80_halt_n;

	wire rom_lo_cs   = ~z80_mreq_n && (z80_addr[15:13] == 3'b000);   // 0x0000-0x1FFF
	wire rom_hi_cs   = ~z80_mreq_n && (z80_addr[15] == 1'b1);        // 0x8000-0xFFFF
	wire ram_cs      = ~z80_mreq_n && (z80_addr[15:11] == 5'b00100); // 0x2000-0x27FF
	wire reg_cs      = ~z80_mreq_n && (z80_addr[15:5] == 11'h200);   // 0x4000-0x401F
	wire oki_cs      = ~z80_mreq_n && (z80_addr[15:12] == 4'h6);     // 0x6000-0x6FFF

	// ─── ROM Z80 64KB raw: 2 BRAM split byte-low / byte-high (32K word) ──────
	// MRA layout DCon: audiocpu @ ioctl_addr 0x4E0000-0x4EFFFF (file fmsnd 64KB raw).
	// WIDE=1 ioctl: 2 byte per word (LSB=primo byte).
	//
	// MAME audiocpu region layout (dcon):
	//   ROM_LOAD     "fmsnd"   0x00000, 0x8000   → primi 32KB del file
	//   ROM_CONTINUE           0x10000, 0x8000   → secondi 32KB del file
	//   ROM_COPY     audiocpu  0x00000 → 0x18000, 0x8000  (alias bank 1)
	//
	// Z80 access:
	//   0x0000-0x1FFF (rom_lo_cs): primi 8KB = file[0x0000-0x1FFF]
	//   0x8000-0xFFFF (rom_hi_cs banked):
	//     bank=0 → file[0x8000-0xFFFF]   (secondi 32KB)
	//     bank=1 → file[0x0000-0x7FFF]   (primi 32KB alias)
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_rom_lo [0:32767];
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_rom_hi [0:32767];
	reg [7:0] z80_rom_lo_q, z80_rom_hi_q;

	wire z80_rom_dl_wr =
		ioctl_download && ioctl_wr && (ioctl_addr >= 27'h4E0000) && (ioctl_addr < 27'h4F0000);
	wire [14:0] z80_rom_dl_word = ioctl_addr[15:1];

	reg rom_bank;

	wire [15:0] z80_rom_byte_addr =
		rom_lo_cs              ? z80_addr :
		(rom_hi_cs & ~rom_bank) ? z80_addr :
		(rom_hi_cs &  rom_bank) ? {1'b0, z80_addr[14:0]} :
		                          z80_addr;

	reg z80_addr_lsb_d;
	always @(posedge clk) begin
		if (z80_rom_dl_wr) begin
			z80_rom_lo[z80_rom_dl_word] <= ioctl_dout[7:0];
			z80_rom_hi[z80_rom_dl_word] <= ioctl_dout[15:8];
		end
		z80_rom_lo_q   <= z80_rom_lo[z80_rom_byte_addr[15:1]];
		z80_rom_hi_q   <= z80_rom_hi[z80_rom_byte_addr[15:1]];
		z80_addr_lsb_d <= z80_rom_byte_addr[0];
	end

	wire [7:0] z80_rom_q = z80_addr_lsb_d ? z80_rom_hi_q : z80_rom_lo_q;

	// ─── RAM Z80 2KB ─────────────────────────────────────────────────────────
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_ram [0:2047];
	reg [7:0] z80_ram_q;

	// synthesis translate_off
	integer z80_ram_init_i;
	initial begin
		for (z80_ram_init_i = 0; z80_ram_init_i < 2048; z80_ram_init_i = z80_ram_init_i + 1)
			z80_ram[z80_ram_init_i] = 8'h00;
	end
	// synthesis translate_on

	always @(posedge clk) begin
		if (ram_cs && !z80_wr_n) z80_ram[z80_addr[10:0]] <= z80_dout;
		z80_ram_q <= z80_ram[z80_addr[10:0]];
	end

	// ─── Sub-region decoder dentro reg_cs ────────────────────────────────────
	wire is_pending_w   = reg_cs && (z80_addr[4:0] == 5'h00) && !z80_wr_n;
	wire is_irq_clear   = reg_cs && (z80_addr[4:0] == 5'h01) && !z80_wr_n;
	wire is_rst10_ack   = reg_cs && (z80_addr[4:0] == 5'h02) && !z80_wr_n;
	wire is_rst18_ack   = reg_cs && (z80_addr[4:0] == 5'h03) && !z80_wr_n;
	wire is_bank_w      = reg_cs && (z80_addr[4:0] == 5'h07) && !z80_wr_n;
	wire is_ym_access   = reg_cs && (z80_addr[4:1] == 4'h4);                      // 0x4008-0x4009
	wire is_ym_w        = is_ym_access && !z80_wr_n;
	wire is_ym_r        = is_ym_access && !z80_rd_n;
	wire is_latch_lo_r  = reg_cs && (z80_addr[4:0] == 5'h10) && !z80_rd_n;
	wire is_latch_hi_r  = reg_cs && (z80_addr[4:0] == 5'h11) && !z80_rd_n;
	wire is_pending_r   = reg_cs && (z80_addr[4:0] == 5'h12) && !z80_rd_n;
	wire is_coin_r      = reg_cs && (z80_addr[4:0] == 5'h13) && !z80_rd_n;
	wire is_data_lo_w   = reg_cs && (z80_addr[4:0] == 5'h18) && !z80_wr_n;
	wire is_data_hi_w   = reg_cs && (z80_addr[4:0] == 5'h19) && !z80_wr_n;
	wire is_coin_w      = reg_cs && (z80_addr[4:0] == 5'h1B) && !z80_wr_n;

	// ─── ROM bank register ──────────────────────────────────────────────────
	always @(posedge clk) begin
		if (reset)
			rom_bank <= 1'b0;
		else if (cen_z80 && is_bank_w)
			rom_bank <= z80_dout[0];
	end

	// ─── Soundlatch main↔sub state ───────────────────────────────────────────
	reg [7:0] main2sub [0:1];
	reg [7:0] sub2main [0:1];
	reg       main2sub_pending;
	reg       sub2main_pending;

	// ─── IRQ controller (IM0 vector RST10/RST18) ─────────────────────────────
	reg rst10_irq, rst10_service;
	reg rst18_irq, rst18_service;
	wire ym_irq_n;
	wire ym_irq = ~ym_irq_n;
	reg  ym_irq_d;

	wire iack_active = ~z80_m1_n && ~z80_iorq_n;
	reg  iack_active_d;
	reg  [7:0] iack_vector_latched;
	wire [7:0] iack_vector_now =
	    (rst18_irq && !rst18_service) ? 8'hDF :
	    (rst10_irq && !rst10_service) ? 8'hD7 :
	                                    8'h00;
	always @(posedge clk) begin
		if (reset) begin
			iack_active_d       <= 1'b0;
			iack_vector_latched <= 8'h00;
		end else begin
			iack_active_d <= iack_active;
			if (iack_active && !iack_active_d) begin
				iack_vector_latched <= iack_vector_now;
			end
		end
	end
	wire [7:0] iack_vector = iack_active_d ? iack_vector_latched : iack_vector_now;

	wire irq_active = (rst10_irq && !rst10_service) || (rst18_irq && !rst18_service);
	assign z80_int_n = ~irq_active;

	always @(posedge clk) begin
		if (reset) begin
			rst10_irq     <= 1'b0;
			rst10_service <= 1'b0;
			rst18_irq     <= 1'b0;
			rst18_service <= 1'b0;
			ym_irq_d      <= 1'b0;
		end else begin
			ym_irq_d <= ym_irq;
			if (ym_irq && !ym_irq_d)        rst10_irq <= 1'b1;
			else if (!ym_irq && ym_irq_d)   rst10_irq <= 1'b0;

			if (snd_cs && snd_wr && snd_addr == 3'd4)
				rst18_irq <= 1'b1;

			if (iack_active_d && !iack_active) begin
				if (iack_vector_latched == 8'hDF) begin
					rst18_service <= 1'b1;
					rst18_irq     <= 1'b0;
				end else if (iack_vector_latched == 8'hD7) begin
					rst10_service <= 1'b1;
				end
			end

			if (cen_z80) begin
				if (is_irq_clear)  rst18_service <= 1'b0;
				if (is_rst10_ack)  rst10_service <= 1'b0;
				if (is_rst18_ack)  rst18_service <= 1'b0;
			end
		end
	end

	// ─── Soundlatch main_w/r logic ──────────────────────────────────────────
	always @(posedge clk) begin
		if (reset) begin
			main2sub[0]      <= 8'd0;
			main2sub[1]      <= 8'd0;
			sub2main[0]      <= 8'd0;
			sub2main[1]      <= 8'd0;
			main2sub_pending <= 1'b0;
			sub2main_pending <= 1'b0;
		end else begin
			if (snd_cs && snd_wr) begin
				case (snd_addr)
					3'd0: main2sub[0] <= snd_wdata[7:0];
					3'd1: main2sub[1] <= snd_wdata[7:0];
					3'd2, 3'd6: begin
						sub2main_pending <= 1'b0;
						main2sub_pending <= 1'b1;
					end
					default: ;
				endcase
			end
			if (cen_z80) begin
				if (is_data_lo_w) sub2main[0] <= z80_dout;
				if (is_data_hi_w) sub2main[1] <= z80_dout;
				if (is_pending_w) begin
					main2sub_pending <= 1'b0;
					sub2main_pending <= 1'b1;
				end
			end
		end
	end

	// snd_rdata: D-Con usa main_r standard (MAME seibusound.cpp:287).
	// offset 2/3 = sub2main bytes (Z80→main), offset 5 = main2sub_pending bit0.
	// Verificato disasm main 68k @ 0x08B6: MOVE.W $A000A,D0 + BTST #0,D0:
	//   - pending=0 → fall-through routine coin (legge sub2main, CMP #$A000)
	//   - pending=1 → BNE skip (main aspetta che Z80 consumi)
	// Quindi al boot pending=0 = path coin libero.
	wire [7:0] main_r_data =
		(snd_addr == 3'd2) ? sub2main[0] :
		(snd_addr == 3'd3) ? sub2main[1] :
		(snd_addr == 3'd5) ? {7'd0, main2sub_pending} :
		                      8'hFF;
	assign snd_rdata = {8'h00, main_r_data};

	// ─── YM3812 (jtopl2) mono ────────────────────────────────────────────────
	wire [7:0] ym_dout;
	wire signed [15:0] ym_snd;
	wire        ym_sample;
	jtopl2 u_jtopl2 (
		.rst    (reset),
		.clk    (clk),
		.cen    (cen_z80_g),
		.din    (z80_dout),
		.addr   (z80_addr[0]),
		.cs_n   (~is_ym_access),
		.wr_n   (z80_wr_n),
		.dout   (ym_dout),
		.irq_n  (ym_irq_n),
		.snd    (ym_snd),
		.sample (ym_sample)
	);

	// ─── OKI M6295 (jt6295) ──────────────────────────────────────────────────
	wire [7:0] oki_dout;
	wire signed [13:0] oki_sound;
	wire        oki_sample;

	jt6295 #(.INTERPOL(0)) u_jt6295 (
		.rst       (reset),
		.clk       (clk),
		.cen       (cen_oki_g),
		.ss        (1'b0),                // PIN7 = LOW
		.wrn       (~(oki_cs & ~z80_wr_n)),
		.din       (z80_dout),
		.dout      (oki_dout),
		.rom_addr  (oki_rom_addr),
		.rom_data  (oki_rom_data),
		.rom_ok    (oki_rom_ok),
		.sound     (oki_sound),
		.sample    (oki_sample)
	);

	// ─── Z80 din mux ─────────────────────────────────────────────────────────
	always @(*) begin
		if (iack_active)         z80_din = iack_vector;
		else if (rom_lo_cs)      z80_din = z80_rom_q;
		else if (rom_hi_cs)      z80_din = z80_rom_q;
		else if (ram_cs)         z80_din = z80_ram_q;
		else if (is_ym_r)        z80_din = ym_dout;
		else if (is_latch_lo_r)  z80_din = main2sub[0];
		else if (is_latch_hi_r)  z80_din = main2sub[1];
		else if (is_pending_r)   z80_din = {7'd0, sub2main_pending};
		else if (is_coin_r)      z80_din = coin_input;
		else if (oki_cs)         z80_din = oki_dout;
		else                     z80_din = 8'hFF;
	end

	// ─── T80s Z80 core ───────────────────────────────────────────────────────
	wire t80_halt_n_g  = ~pause;
	wire t80_busrq_n   = 1'b1;
	wire t80_wait_n    = 1'b1;
	wire t80_nmi_n     = 1'b1;
	wire t80_reset_n   = ~reset & ~snd_reset_in;

	T80s u_z80 (
		.RESET_n (t80_reset_n),
		.CLK     (clk),
		.CEN     (cen_z80 & t80_halt_n_g),
		.WAIT_n  (t80_wait_n),
		.INT_n   (z80_int_n),
		.NMI_n   (t80_nmi_n),
		.BUSRQ_n (t80_busrq_n),
		.M1_n    (z80_m1_n),
		.MREQ_n  (z80_mreq_n),
		.IORQ_n  (z80_iorq_n),
		.RD_n    (z80_rd_n),
		.WR_n    (z80_wr_n),
		.RFSH_n  (),
		.HALT_n  (z80_halt_n),
		.BUSAK_n (z80_busak_n),
		.OUT0    (1'b0),
		.A       (z80_addr),
		.DI      (z80_din),
		.DO      (z80_dout),
		.REG     ()
	);

	// ─── Mixer audio: YM3812 mono + OKI mono → AUDIO_L/R (duplicato mono) ───
	// Volumi OSD Q4.4. Mul a signed 23-bit poi >>4.
	wire signed [22:0] ym_v   = $signed(ym_snd)              * $signed({1'b0, fm_vol_q44});
	wire signed [22:0] oki_v  = $signed({oki_sound, 2'b00})  * $signed({1'b0, oki_vol_q44});
	wire signed [18:0] ym_s   = ym_v[22:4];
	wire signed [18:0] oki_s  = oki_v[22:4];
	wire signed [19:0] mix    = {ym_s[18], ym_s} + {oki_s[18], oki_s};

	always @(posedge clk) begin
		if (reset) begin
			audio_l <= 16'sd0;
			audio_r <= 16'sd0;
		end else begin
			audio_l <= (mix > 20'sd32767)   ? 16'sh7FFF :
			           (mix < -20'sd32767) ? 16'sh8000 :
			                                  mix[15:0];
			audio_r <= audio_l;   // mono → duplicato
		end
	end

endmodule
