
//--------------------------------------------------------------------------------
// Module      : hdmi_tx_phy (修正版)
// Description : HDMI TX PHY for XCKU5P
//               - 正确映射通道：物理通道0 = 蓝色（含同步），通道1 = 绿色，通道2 = 红色
//               - 增加 valid 寄存，防止 hdmi_gearbox 输出无效数据
//--------------------------------------------------------------------------------
module hdmi_tx_phy (
    input  wire        pclk,
    input  wire        pixel_clk_5x,
    input  wire        pixel_clk_2_5x,
    input  wire        reset_n,
    input  wire [29:0] tx_data,        // {blue[9:0], green[9:0], red[9:0]}
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,    // {blue, green, red}
    output wire [2:0]  tmds_data_n
);

    wire reset = ~reset_n;
    localparam [9:0] CLK_PATTERN = 10'b1111100000;

    // 拆分输入颜色
    wire [9:0] blue  = tx_data[29:20];
    wire [9:0] green = tx_data[19:10];
    wire [9:0] red   = tx_data[9:0];

    // 物理通道顺序：0->蓝, 1->绿, 2->红
    wire [9:0] channel_data [0:2];
    assign channel_data[0] = blue;
    assign channel_data[1] = green;
    assign channel_data[2] = red;

    // 中间信号
    reg  [3:0] data_4b_reg [0:2];
    wire [3:0] data_4b     [0:2];
    wire [2:0] data_valid;
    wire [2:0] data_serial;
    reg  [3:0] clk_4b_reg;
    wire [3:0] clk_4b;
    wire       clk_valid;
    wire       clk_serial;

    //------------------------------------------------------------------------
    // 数据通道（带 valid 寄存）
    //------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : gen_data
            // 10→4 hdmi_gearbox
            hdmi_gearbox #(
                .IN_W  (10),
                .OUT_W (4)
            ) u_gearbox (
                .wr_clk   (pclk),
                .rd_clk   (pixel_clk_2_5x),
                .reset    (reset),
                .wr_data  (channel_data[i]),
                .rd_data  (data_4b[i]),
                .rd_valid (data_valid[i])
            );

            // 仅在 valid 有效时更新寄存器
            always @(posedge pixel_clk_2_5x or posedge reset) begin
                if (reset)
                    data_4b_reg[i] <= 4'b0;
                else if (data_valid[i])
                    data_4b_reg[i] <= data_4b[i];
            end

            // 4:1 OSERDESE3
            OSERDESE3 #(
                .DATA_WIDTH (4),
                .SIM_DEVICE ("ULTRASCALE_PLUS")
            ) u_oserdes (
                .CLK    (pixel_clk_5x),
                .CLKDIV (pixel_clk_2_5x),
                .RST    (reset),
                .D      ({4'b0, data_4b_reg[i]}),
                .OQ     (data_serial[i])
            );
        end
    endgenerate

    //------------------------------------------------------------------------
    // 时钟通道（同样带 valid 寄存）
    //------------------------------------------------------------------------
    hdmi_gearbox #(
        .IN_W  (10),
        .OUT_W (4)
    ) u_gearbox_clk (
        .wr_clk   (pclk),
        .rd_clk   (pixel_clk_2_5x),
        .reset    (reset),
        .wr_data  (CLK_PATTERN),
        .rd_data  (clk_4b),
        .rd_valid (clk_valid)
    );

    always @(posedge pixel_clk_2_5x or posedge reset) begin
        if (reset)
            clk_4b_reg <= 4'b0;
        else if (clk_valid)
            clk_4b_reg <= clk_4b;
    end

    OSERDESE3 #(
        .DATA_WIDTH (4),
        .SIM_DEVICE ("ULTRASCALE_PLUS")
    ) u_oserdes_clk (
        .CLK    (pixel_clk_5x),
        .CLKDIV (pixel_clk_2_5x),
        .RST    (reset),
        .D      ({4'b0, clk_4b_reg}),
        .OQ     (clk_serial)
    );

    //------------------------------------------------------------------------
    // 差分输出（物理通道索引直接对应）
    //------------------------------------------------------------------------
    OBUFDS u_obufds_clk (
        .I  (clk_serial),
        .O  (tmds_clk_p),
        .OB (tmds_clk_n)
    );

    OBUFDS u_obufds_ch0 (
        .I  (data_serial[0]),
        .O  (tmds_data_p[0]),
        .OB (tmds_data_n[0])
    );

    OBUFDS u_obufds_ch1 (
        .I  (data_serial[1]),
        .O  (tmds_data_p[1]),
        .OB (tmds_data_n[1])
    );

    OBUFDS u_obufds_ch2 (
        .I  (data_serial[2]),
        .O  (tmds_data_p[2]),
        .OB (tmds_data_n[2])
    );

endmodule



module hdmi_gearbox #(
    parameter integer IN_W              = 10,
    parameter integer OUT_W             = 4,
    parameter integer OUTPUT_REG_STAGES = 0,
    parameter integer RD_RST_DELAY      = 0
)(
    input  wire                 wr_clk,
    input  wire                 rd_clk,
    input  wire                 reset,
    input  wire [IN_W-1:0]      wr_data,
    output wire [OUT_W-1:0]     rd_data,
    output wire                 rd_valid
);
    localparam integer DEPTH             = 32;
    // ====================================================================
    // 参数计算
    // ====================================================================
    localparam integer ADDR_W = $clog2(DEPTH);
    
    function integer gcd(input integer a, input integer b);
        integer tmp_a, tmp_b, tmp_t;
    begin
        tmp_a = (a > b) ? a : b;
        tmp_b = (a > b) ? b : a;
        while (tmp_b != 0) begin
            tmp_t = tmp_b;
            tmp_b = tmp_a % tmp_b;
            tmp_a = tmp_t;
        end
        gcd = tmp_a;
    end
    endfunction

    function integer lcm(input integer a, input integer b);
    begin
        lcm = (a / gcd(a, b)) * b;
    end
    endfunction

    localparam integer LCM_W = lcm(IN_W, OUT_W);
    localparam integer READS_PER_CYCLE = LCM_W / IN_W;  // 一个周期需要读多少次
    localparam integer OUTPUTS_PER_CYCLE = LCM_W / OUT_W; // 一个周期需要输出多少次
    localparam integer OFFSET_W = $clog2(2*IN_W);  // bit_offset 位宽

    // 启动延迟：确保缓冲区有足够数据
    // localparam integer WARM_UP_CYCLES = (IN_W >= OUT_W) ? 
    //                                     ((READS_PER_CYCLE + 1) * 2) :
    //                                     ((OUT_W + IN_W - 1) / IN_W + 2);
    localparam integer WARM_UP_CYCLES = (IN_W >= OUT_W) ? 
                                        32'd0 : OUT_W/IN_W+1;

    localparam integer TOTAL_RD_DELAY = RD_RST_DELAY + WARM_UP_CYCLES;



    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_rst_sync;
    always @(posedge wr_clk or posedge reset) begin
        if (reset)
            wr_rst_sync <= 2'b11;
        else
            wr_rst_sync <= {wr_rst_sync[0], 1'b0};
    end
    wire wr_rst_s = wr_rst_sync[1];

    // ====================================================================
    // 写侧
    // ====================================================================
    reg [ADDR_W-1:0] wr_addr;
    always @(posedge wr_clk or posedge wr_rst_s) begin
        if (wr_rst_s)
            wr_addr <= {ADDR_W{1'b0}};
        else
            wr_addr <= wr_addr + 1'b1;
    end

    // ====================================================================
    // RAM（参数化）
    // ====================================================================
    wire [IN_W-1:0] mem_out;

    for (genvar i = 0; i < IN_W; i = i + 1) begin : gen_ram
        RAM32X1D #(.INIT(32'h0)) ram_inst (
            .D     (wr_data[i]),
            .WCLK  (wr_clk),
            .WE    (~wr_rst_s),
            .A0    (wr_addr[0]),
            .A1    (wr_addr[1]),
            .A2    (wr_addr[2]),
            .A3    (wr_addr[3]),
            .A4    (wr_addr[4]),
            .DPRA0 (rd_addr[0]),
            .DPRA1 (rd_addr[1]),
            .DPRA2 (rd_addr[2]),
            .DPRA3 (rd_addr[3]),
            .DPRA4 (rd_addr[4]),
            .DPO   (mem_out[i])
        );
    end

    // ====================================================================
    // 读侧复位同步
    // ====================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_rst_rd_sync;
    always @(posedge rd_clk or posedge reset) begin
        if (reset)
            wr_rst_rd_sync <= 2'b11;
        else
            wr_rst_rd_sync <= {wr_rst_rd_sync[0], wr_rst_s};
    end
    wire wr_released_in_rd = ~wr_rst_rd_sync[1];

    reg rd_rst_eff;
    reg [15:0] dly_cnt;
    always @(posedge rd_clk or posedge reset) begin
        if (reset) begin
            rd_rst_eff <= 1'b1;
            dly_cnt    <= 16'd0;
        end else begin
            if (!wr_released_in_rd) begin
                rd_rst_eff <= 1'b1;
                dly_cnt    <= 16'd0;
            end else if (dly_cnt < TOTAL_RD_DELAY) begin
                dly_cnt    <= dly_cnt + 1'b1;
                rd_rst_eff <= 1'b1;
            end else begin
                rd_rst_eff <= 1'b0;
            end
        end
    end

    // ====================================================================
    // 读侧核心：双字缓冲 + 无间隙输出
    // ====================================================================
    reg [ADDR_W-1:0] rd_addr;
    reg [IN_W-1:0]  curr_word;      // 当前字
    reg [IN_W-1:0]  next_word;      // 下一个字
    reg [OFFSET_W-1:0] bit_offset;  // 输出位偏移（0 ~ IN_W-1）

    wire [IN_W-1:0] next_mem = mem_out;  // 立即读下一个字

    // 组合逻辑：从双字缓冲区提取 OUT_W 位
    wire [2*IN_W-1:0] combined = {next_word, curr_word};
    wire [OUT_W-1:0]  extracted_data = combined[bit_offset +: OUT_W];

    reg [OUT_W-1:0] tx_data;
    reg             data_valid;

    always @(posedge rd_clk or posedge rd_rst_eff) begin
        if (rd_rst_eff) begin
            rd_addr <= {ADDR_W{1'b0}};
            curr_word <= {IN_W{1'b0}};
            next_word <= {IN_W{1'b0}};
            bit_offset <= {OFFSET_W{1'b0}};
            tx_data <= {OUT_W{1'b0}};
            data_valid <= 1'b0;
        end else begin
            // 每个周期都输出 OUT_W 位
            tx_data <= extracted_data;
            data_valid <= 1'b1;

            // 更新偏移量
            bit_offset <= bit_offset + OUT_W;

            // 当偏移量超过一个字时，滚动缓冲区
            if ((bit_offset + OUT_W) >= IN_W) begin
                curr_word <= next_word;
                next_word <= next_mem;
                rd_addr <= rd_addr + 1'b1;
                
                // 重新计算偏移量（考虑进位）
                if ((bit_offset + OUT_W) >= (2 * IN_W)) begin
                    bit_offset <= (bit_offset + OUT_W) - (2 * IN_W);
                end else begin
                    bit_offset <= (bit_offset + OUT_W) - IN_W;
                end
            end
        end
    end

    // ====================================================================
    // 启动延迟控制
    // ====================================================================
    reg [7:0] startup_cnt;
    reg [OUT_W-1:0] data_reg;
    reg             valid_reg;

    always @(posedge rd_clk or posedge rd_rst_eff) begin
        if (rd_rst_eff) begin
            startup_cnt <= 8'd0;
            data_reg <= {OUT_W{1'b0}};
            valid_reg <= 1'b0;
        end else begin
            if (startup_cnt < WARM_UP_CYCLES) begin
                startup_cnt <= startup_cnt + 1'b1;
                valid_reg <= 1'b0;
            end else begin
                valid_reg <= data_valid;
            end
            data_reg <= tx_data;
        end
    end

    // ====================================================================
    // 可选流水线
    // ====================================================================
    if (OUTPUT_REG_STAGES == 0) begin : no_pipe
        assign rd_data  = data_reg;
        assign rd_valid = valid_reg;
    end else begin : with_pipe
        reg [OUT_W-1:0] data_pipe [0:OUTPUT_REG_STAGES-1];
        reg             valid_pipe [0:OUTPUT_REG_STAGES-1];
        integer s;
        always @(posedge rd_clk or posedge rd_rst_eff) begin
            if (rd_rst_eff) begin
                for (s = 0; s < OUTPUT_REG_STAGES; s = s + 1) begin
                    data_pipe[s]  <= {OUT_W{1'b0}};
                    valid_pipe[s] <= 1'b0;
                end
            end else begin
                data_pipe[0]  <= data_reg;
                valid_pipe[0] <= valid_reg;
                for (s = 1; s < OUTPUT_REG_STAGES; s = s + 1) begin
                    data_pipe[s]  <= data_pipe[s-1];
                    valid_pipe[s] <= valid_pipe[s-1];
                end
            end
        end
        assign rd_data  = data_pipe[OUTPUT_REG_STAGES-1];
        assign rd_valid = valid_pipe[OUTPUT_REG_STAGES-1];
    end

endmodule
