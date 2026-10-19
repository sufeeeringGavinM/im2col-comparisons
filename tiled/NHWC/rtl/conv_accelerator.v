// Full-layer scheduler and serialized SRAM-like memory transfers.
// Backing memory is external to this module: one-cycle enabled reads, edge writes.
// Each external word holds one operand in its low bits or one ACC_WIDTH result.
`timescale 1ns/1ps
module conv_accelerator #(
    parameter ARRAY_SIZE=10, BIT_WIDTH=8, ACC_WIDTH=32,
    parameter INPUT_ADDR_WIDTH=8, OUTPUT_ADDR_WIDTH=8, KERNEL_ADDR_WIDTH=8,
    parameter CFG_WIDTH=32, MEM_ADDR_WIDTH=32,
    parameter MEM_DATA_WIDTH=(ACC_WIDTH>BIT_WIDTH ? ACC_WIDTH : BIT_WIDTH)
) (
    input clk, nrst, start,
    output busy, output reg done,
    input [CFG_WIDTH-1:0] cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,
    input [MEM_ADDR_WIDTH-1:0] cfg_input_base,cfg_kernel_base,cfg_output_base,
    output reg mem_re, mem_we,
    output reg [MEM_ADDR_WIDTH-1:0] mem_raddr,mem_waddr,
    input [MEM_DATA_WIDTH-1:0] mem_rdata,
    output reg [MEM_DATA_WIDTH-1:0] mem_wdata
);
  localparam INPUT_DEPTH=2**INPUT_ADDR_WIDTH, OUTPUT_DEPTH=2**OUTPUT_ADDR_WIDTH,
             KERNEL_DEPTH=2**KERNEL_ADDR_WIDTH;
  localparam IDLE=0, SETUP=1, PLAN_TILE=2, PREPARE=3,
             INPUT_READ=4, INPUT_WRITE=5, KERNEL_READ=6, KERNEL_WRITE=7,
             START_CORE=8, WAIT_CORE=9, OUTPUT_READ=10, OUTPUT_WRITE=11, NEXT_TILE=12;
  reg [3:0] state;
  reg [CFG_WIDTH-1:0] N,C,H,W,K,R,S,P,Q,pad_i,pad_j,stride_i,stride_j,dilation_i,dilation_j;
  reg [MEM_ADDR_WIDTH-1:0] input_base,kernel_base,output_base;
  reg [CFG_WIDTH-1:0] n0,k0,p0,q0,c0,tap_r,tap_s;
  reg [CFG_WIDTH-1:0] tile_k,tile_q,tile_c,c_step,q_limit;
  reg tap_mode;
  reg [CFG_WIDTH-1:0] patch_h,patch_w,patch_i,patch_j,local_pad_i,local_pad_j;
  reg [CFG_WIDTH-1:0] bank_index,word_index;
  wire [CFG_WIDTH-1:0] local_R=tap_mode?1:R, local_S=tap_mode?1:S;
  wire [CFG_WIDTH-1:0] patch_words=patch_h*patch_w;
  wire [CFG_WIDTH-1:0] kernel_words=tile_c*local_R*local_S;
  wire core_busy,core_done;
  wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] stored_output;
  reg [ARRAY_SIZE-1:0] input_we,kernel_we;
  reg [ARRAY_SIZE-1:0][INPUT_ADDR_WIDTH-1:0] input_addr;
  reg [ARRAY_SIZE-1:0][KERNEL_ADDR_WIDTH-1:0] kernel_addr;
  reg [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] input_data,kernel_data;
  assign busy=state!=IDLE;

  // Conservative full-kernel footprint selects a row width that always fits.
  // A single-tap fallback handles kernels or dilated footprints too large even
  // for one output. It keeps the original im2col address generator in use.
  wire [63:0] extent_i=64'(dilation_i)*(R-1)+1;
  wire [63:0] extent_j=64'(dilation_j)*(S-1)+1;
  wire [63:0] taps=64'(R)*S;
  wire needs_taps=(taps>KERNEL_DEPTH || extent_i*extent_j>INPUT_DEPTH);
  wire [63:0] plan_c=needs_taps?KERNEL_DEPTH:KERNEL_DEPTH/taps;
  wire [63:0] plan_q=needs_taps ? 1+(INPUT_DEPTH-1)/stride_j :
                              1+(INPUT_DEPTH/extent_i-extent_j)/stride_j;

  // Clip a real input rectangle to the image. Local padding is the distance
  // from the requested origin to its clipped origin. No padded pixels are DMA'd.
  wire signed [63:0] raw_i=$signed(64'(p0*64'(stride_i)))+$signed(tap_mode?64'(tap_r)*dilation_i:64'd0)-$signed(64'(pad_i));
  wire signed [63:0] raw_j=$signed(64'(q0*64'(stride_j)))+$signed(tap_mode?64'(tap_s)*dilation_j:64'd0)-$signed(64'(pad_j));
  wire signed [63:0] end_i=raw_i+$signed(tap_mode?64'd1:extent_i);
  wire signed [63:0] end_j=raw_j+$signed(64'(tile_q-1)*stride_j)+(tap_mode?64'sd1:$signed(extent_j));
  wire signed [63:0] clip_i=raw_i<0?0:raw_i, clip_j=raw_j<0?0:raw_j;
  wire signed [63:0] stop_i=end_i>$signed(64'(H))?$signed(64'(H)):end_i;
  wire signed [63:0] stop_j=end_j>$signed(64'(W))?$signed(64'(W)):end_j;
  wire [63:0] clipped_h=stop_i>clip_i?stop_i-clip_i:0;
  wire [63:0] clipped_w=stop_j>clip_j?stop_j-clip_j:0;

  // Memory read data is consumed in the following WRITE state, never on the
  // edge that issues its read. Local output reads follow the same rule.
  always @* begin
    mem_re=0;mem_we=0;mem_raddr=0;mem_waddr=0;mem_wdata=0;
    input_we=0;kernel_we=0;input_addr=0;kernel_addr=0;input_data=0;kernel_data=0;
    if(nrst) begin
    case(state)
      INPUT_READ: begin
        mem_re=1;
        mem_raddr=MEM_ADDR_WIDTH'(64'(input_base)+
          ((64'(n0)*C+c0+bank_index)*H+patch_i+word_index/patch_w)*W+patch_j+word_index%patch_w);
      end
      INPUT_WRITE: begin
        input_we[bank_index]=1;
        input_addr[bank_index]=INPUT_ADDR_WIDTH'(word_index);
        input_data[bank_index]=mem_rdata[BIT_WIDTH-1:0];
      end
      KERNEL_READ: begin
        mem_re=1;
        mem_raddr=MEM_ADDR_WIDTH'(64'(kernel_base)+
          ((64'(k0+bank_index)*C+c0+word_index/(local_R*local_S))*R*S)+
          (tap_mode ? 64'(tap_r)*S+tap_s : word_index%(local_R*local_S)));
      end
      KERNEL_WRITE: begin
        kernel_we[bank_index]=1;
        kernel_addr[bank_index]=KERNEL_ADDR_WIDTH'(word_index);
        kernel_data[bank_index]=mem_rdata[BIT_WIDTH-1:0];
      end
      OUTPUT_WRITE: begin
        mem_we=1;
        mem_waddr=MEM_ADDR_WIDTH'(64'(output_base)+((64'(n0)*K+k0+bank_index)*P+p0)*Q+q0+word_index);
        mem_wdata=MEM_DATA_WIDTH'(stored_output[bank_index]);
      end
    endcase
    end
  end

  conv_core #(.ARRAY_SIZE(ARRAY_SIZE),.BIT_WIDTH(BIT_WIDTH),.ACC_WIDTH(ACC_WIDTH),
    .INPUT_ADDR_WIDTH(INPUT_ADDR_WIDTH),.OUTPUT_ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
    .KERNEL_ADDR_WIDTH(KERNEL_ADDR_WIDTH),.CFG_WIDTH(CFG_WIDTH)) u_core (
    .clk(clk),.nrst(nrst),.start(state==START_CORE),.busy(core_busy),.done(core_done),
    .cfg_continue_sum(c0!=0 || tap_r!=0 || tap_s!=0),
    .cfg_N(CFG_WIDTH'(1)),.cfg_C(tile_c),.cfg_H(patch_h),.cfg_W(patch_w),
    .cfg_K(tile_k),.cfg_R(local_R),.cfg_S(local_S),.cfg_P(CFG_WIDTH'(1)),.cfg_Q(tile_q),
    .cfg_pad_i(local_pad_i),.cfg_pad_j(local_pad_j),
    .cfg_stride_i(stride_i),.cfg_stride_j(stride_j),
    .cfg_dilation_i(dilation_i),.cfg_dilation_j(dilation_j),
    .sram_we_ext(input_we),.sram_waddr_ext(input_addr),.sram_wdata_ext(input_data),
    .kernel_we_ext(kernel_we),.kernel_waddr_ext(kernel_addr),.kernel_wdata_ext(kernel_data),
    .output_read_enable(state==OUTPUT_READ),.output_read_addr(OUTPUT_ADDR_WIDTH'(word_index)),
    .output_read_data(stored_output),.acc_col_out()
  );

  always @(posedge clk) begin
    if(!nrst) begin
      state<=IDLE;done<=0;
      N<=1;C<=1;H<=1;W<=1;K<=1;R<=1;S<=1;P<=1;Q<=1;
      pad_i<=0;pad_j<=0;stride_i<=1;stride_j<=1;dilation_i<=1;dilation_j<=1;
      input_base<=0;kernel_base<=0;output_base<=0;
      n0<=0;k0<=0;p0<=0;q0<=0;c0<=0;tap_r<=0;tap_s<=0;
      tile_k<=0;tile_q<=0;tile_c<=0;c_step<=1;q_limit<=1;tap_mode<=0;
      patch_h<=0;patch_w<=0;patch_i<=0;patch_j<=0;local_pad_i<=0;local_pad_j<=0;
      bank_index<=0;word_index<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(start) begin
          N<=cfg_N;C<=cfg_C;H<=cfg_H;W<=cfg_W;K<=cfg_K;R<=cfg_R;S<=cfg_S;P<=cfg_P;Q<=cfg_Q;
          pad_i<=cfg_pad_i;pad_j<=cfg_pad_j;stride_i<=cfg_stride_i;stride_j<=cfg_stride_j;
          dilation_i<=cfg_dilation_i;dilation_j<=cfg_dilation_j;
          input_base<=cfg_input_base;kernel_base<=cfg_kernel_base;output_base<=cfg_output_base;
          n0<=0;k0<=0;p0<=0;q0<=0;state<=SETUP;
        end
        SETUP: begin
          tap_mode<=needs_taps;
          c_step<=CFG_WIDTH'(plan_c<ARRAY_SIZE?plan_c:ARRAY_SIZE);
          q_limit<=CFG_WIDTH'(plan_q<OUTPUT_DEPTH?plan_q:OUTPUT_DEPTH);
          state<=PLAN_TILE;
        end
        PLAN_TILE: begin
          tile_q<=Q-q0<q_limit?Q-q0:q_limit;
          tile_k<=K-k0<ARRAY_SIZE?K-k0:CFG_WIDTH'(ARRAY_SIZE);
          c0<=0;tap_r<=0;tap_s<=0;state<=PREPARE;
        end
        PREPARE: begin
          tile_c<=C-c0<c_step?C-c0:c_step;
          patch_h<=CFG_WIDTH'(clipped_h);patch_w<=CFG_WIDTH'(clipped_w);
          patch_i<=CFG_WIDTH'(clip_i);patch_j<=CFG_WIDTH'(clip_j);
          local_pad_i<=CFG_WIDTH'(clip_i-raw_i);local_pad_j<=CFG_WIDTH'(clip_j-raw_j);
          bank_index<=0;word_index<=0;
          state<=(clipped_h!=0 && clipped_w!=0)?INPUT_READ:KERNEL_READ;
        end
        INPUT_READ: state<=INPUT_WRITE;
        INPUT_WRITE: begin
          state<=INPUT_READ;
          if(word_index+1<patch_words) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_c) bank_index<=bank_index+1'b1;
            else begin bank_index<=0;state<=KERNEL_READ;end
          end
        end
        KERNEL_READ: state<=KERNEL_WRITE;
        KERNEL_WRITE: begin
          state<=KERNEL_READ;
          if(word_index+1<kernel_words) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_k) bank_index<=bank_index+1'b1;
            else begin bank_index<=0;state<=START_CORE;end
          end
        end
        START_CORE: state<=WAIT_CORE;
        WAIT_CORE: if(core_done) begin
          if(tap_mode && tap_s+1<S) begin tap_s<=tap_s+1'b1;state<=PREPARE;end
          else if(tap_mode && tap_r+1<R) begin tap_s<=0;tap_r<=tap_r+1'b1;state<=PREPARE;end
          else if(c0+tile_c<C) begin
            c0<=c0+tile_c;tap_r<=0;tap_s<=0;state<=PREPARE;
          end else begin bank_index<=0;word_index<=0;state<=OUTPUT_READ;end
        end
        OUTPUT_READ: state<=OUTPUT_WRITE;
        OUTPUT_WRITE: begin
          state<=OUTPUT_READ;
          if(word_index+1<tile_q) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_k) bank_index<=bank_index+1'b1;
            else state<=NEXT_TILE;
          end
        end
        NEXT_TILE: begin
          state<=PLAN_TILE;
          if(q0+tile_q<Q) q0<=q0+tile_q;
          else begin
            q0<=0;
            if(p0+1<P) p0<=p0+1'b1;
            else begin
              p0<=0;
              if(k0+tile_k<K) k0<=k0+tile_k;
              else begin
                k0<=0;
                if(n0+1<N) n0<=n0+1'b1;
                else begin state<=IDLE;done<=1;end
              end
            end
          end
        end
        default: state<=IDLE;
      endcase
    end
  end
endmodule
