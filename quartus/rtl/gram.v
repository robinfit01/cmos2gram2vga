/*******************************************************************************************
*  Name         :gram.v
*  Description  :one frame-->gram(VIDEO_ROW_SIZE*VIDEO_COL_SIZE)-->VGA,将SDRAM用作显存
*                 没有持久性的同步对齐策略,乒乓操作只切换bank地址,一帧数据全在一个bank内。
*                VIDEO_ROW_SIZE * VIDEO_COL_SIZE == (TWO_FIFO_DEPTH/2)*ROW_SAVE2SDRAM
*                (TWO_FIFO_DEPTH/2) == COL_SAVE2SDRAM
*  Origin       :190123
*                190127
*  Author       :helrori2011@gmail.com
*  Reference    :
********************************************************************************************/
`include "vga_define.v"
module gram
#(
    parameter   
                //TODO:
                //1. Change the parameter in sdram_core.v according to your SDRAM.
                //   Please makesure that SDRAM can save one frame of image in one BANK.
                //   (2^ROW_WIDTH*2^COL_WIDTH >= VIDEO_ROW_SIZE*VIDEO_COL_SIZE)
                //2. Makesure  GDATA CMOS  output H_ACTIVE*V_ACTIVE sizes and pclk the same as VGA.
                //3. Change the define in vga_define.v
                //4. Change the pll frequency of c2.
                TWO_FIFO_DEPTH  = 10'd512, //generally do not need to change 
                VIDEO_ROW_SIZE  = `H_ACTIVE,
                VIDEO_COL_SIZE  = `V_ACTIVE,
                ROW_SAVE2SDRAM  = (VIDEO_ROW_SIZE*VIDEO_COL_SIZE*2)/TWO_FIFO_DEPTH

                
)
(
    //CLOCK
    input   wire             clk            ,//100Mhz
    input   wire             clk_ref        ,//sdram_clk 100Mhz -80 degrees
    input   wire             rst_n          ,
    //GDATA CMOS 
    input   wire             wr_clk         ,
    input   wire             wr_en          ,
    input   wire    [15 :  0]wr_data        ,
    input   wire             wr_frame_sync  ,//not use
  
    //GDATA VGA 
    input   wire             rd_clk         ,//VGA clk
    input   wire             rd_en          ,//VGA RGB data valid
    output  wire    [15 :  0]rd_data        ,//to RGB565 output
    input   wire             rd_frame_sync  ,//vga frame sync: vga_vsync,仅用于上电等待2帧后开始VGA读FIFO的同步操作
   
    //SDRAM
    output  wire             sdram_init_done,     
    output  wire    [12 :  0]sdram_addr     ,//(init,read,write)
    output  wire    [1  :  0]sdram_bkaddr   ,//(init,read,write)
    inout   wire    [15 :  0]sdram_data     ,//仅支持16bits (read,write)
    output  wire             sdram_clk      ,
    output  wire             sdram_cke      ,//always 1
    output  wire             sdram_cs_n     ,//always 0
    output  wire             sdram_ras_n    ,
    output  wire             sdram_cas_n    ,
    output  wire             sdram_we_n     ,
    output  wire             sdram_dqml     ,//not use,always 0
    output  wire             sdram_dqmh      //not use,always 0
);
reg  wr_frame_done,rd_frame_done;
reg  [1 :0]wr_bank_addr,rd_bank_addr;
reg  [12:0]wr_row_addr ,rd_row_addr ;
wire wr_sdram_request,rd_sdram_request;

wire [15:0]wr_sdram_data,rd_sdram_data;
wire wr_sdram_allow,wr_sdram_busy,rd_sdram_allow,rd_sdram_busy;
wire [8: 0]wrusedw,rdusedw;
/*******************************************************************************************
*  dcfifo_input --> sdram_core
********************************************************************************************/
/*
*   if dcfifo_input data > 256 then set wr_sdram_request a pulse(check wr_sdram_busy first)
*/

reg  [1:0]buff0;
wire negedge_wr_sdram_busy = buff0 == 2'b10;
reg  wr_b;
assign wr_sdram_request = wr_b; 
reg [1:0]state_f2s;
localparam IDLE_ = 3'd0,SET_WR_REQ = 3'd1 ,WT_NEG_BUSY_ = 3'd2;

always@(posedge clk or negedge rst_n)begin
    if(!rst_n)  buff0   <= 2'd0;
    else        buff0   <= {buff0[0],wr_sdram_busy};  
end
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state_f2s <= IDLE_;
        wr_b      <= 0;
    end else begin
        case(state_f2s)
        IDLE_:begin
            wr_b        <= 0;
            if(rdusedw >= (TWO_FIFO_DEPTH/10'd2)/*9'd256*/ && wr_sdram_busy == 0 && sdram_init_done == 1) state_f2s <= SET_WR_REQ;
            else state_f2s <= state_f2s;
        end
        SET_WR_REQ:begin
            wr_b        <= 1;
            state_f2s   <= WT_NEG_BUSY_;
        end 
        WT_NEG_BUSY_:begin
            wr_b        <= 0;
            state_f2s   <= (negedge_wr_sdram_busy)?IDLE_:WT_NEG_BUSY_;
        end           
        default:state_f2s   <= IDLE_;
        endcase
    end
end
/*
*   切换策略:
*   当写入完一帧时立即无条件切换 wr_bank_addr 。读完一帧时判断wr_bank_addr
*   是否与rd_bank_addr一样，一样则切换rd_bank_addr，否则rd_bank_addr不变
*/
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        wr_row_addr     <= 13'd0;
        wr_bank_addr    <= 2'b00;
    end else if(negedge_wr_sdram_busy)begin/*negedge of wr_sdram_busy*/
        if(wr_row_addr == ROW_SAVE2SDRAM - 1)begin//写完规定行数
            wr_row_addr <= 13'd0;
            wr_bank_addr<= ~wr_bank_addr;
        end else begin
            wr_row_addr <= wr_row_addr + 1'd1;
            wr_bank_addr<= wr_bank_addr;
        end
    end
end
/*******************************************************************************************
*  sdram_core   --> dcfifo_output
********************************************************************************************/
/*
*   if dcfifo_output data < 256 then set rd_sdram_request a pulse(check rd_sdram_busy first)
*/
reg  [1:0]buff1;
wire negedge_rd_sdram_busy = buff1 == 2'b10;
reg  rd_b;
assign rd_sdram_request = rd_b; 
reg [1:0]state_s2f;
localparam IDLE = 3'd0,SET_RD_REQ = 3'd1 ,WT_NEG_BUSY = 3'd2;

always@(posedge clk or negedge rst_n)begin
    if(!rst_n)  buff1   <= 2'd0;
    else        buff1   <= {buff1[0],rd_sdram_busy};
end
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state_s2f   <= IDLE;
        rd_b        <= 0;
    end else begin
        case(state_s2f)
        IDLE:begin
            rd_b        <= 0;
            if(wrusedw < (TWO_FIFO_DEPTH/10'd2)/*9'd256*/ && rd_sdram_busy == 0 && sdram_init_done == 1) state_s2f <= SET_RD_REQ;
            else state_s2f <= state_s2f;
        end
        SET_RD_REQ:begin
            rd_b        <= 1;
            state_s2f   <= WT_NEG_BUSY;
        end 
        WT_NEG_BUSY:begin
            rd_b        <= 0;
            state_s2f   <= (negedge_rd_sdram_busy)?IDLE:WT_NEG_BUSY;
        end           
        default:state_s2f   <= IDLE;
        endcase
    end
end
/*
*   切换策略:
*   当写入完一帧时立即无条件切换 wr_bank_addr 。读完一帧时判断wr_bank_addr
*   是否与rd_bank_addr一样，一样则切换rd_bank_addr，否则rd_bank_addr不变
*/
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        rd_row_addr     <= 13'd0;
        rd_bank_addr    <= 2'b11;
    end else if(negedge_rd_sdram_busy)begin/*negedge of rd_sdram_busy*/
        if(rd_row_addr == ROW_SAVE2SDRAM - 1)begin//写完规定行数
            rd_row_addr <= 13'd0;
            if(rd_bank_addr == wr_bank_addr)
                rd_bank_addr<= ~rd_bank_addr;
            else
                rd_bank_addr<= rd_bank_addr;
        end else begin
            rd_row_addr <= rd_row_addr + 1'd1;
            rd_bank_addr<= rd_bank_addr;
        end
    end
end
/*
*    刚上电VGA不能立即读FIFO。要与VGA帧同步
*/
reg vga_access_allow;
reg [1:0]buff2;
always@(posedge rd_clk or negedge rst_n)begin
    if(!rst_n)  buff2   <= 2'd0;
    else        buff2   <= {buff2[0],rd_frame_sync};
end
reg [1:0]frame_cnt;
always@(posedge rd_clk or negedge rst_n)begin
    if(!rst_n)begin
        frame_cnt <= 'd0;
        vga_access_allow <= 0;
    end else if(buff2 == 2'b10)begin
        frame_cnt <= frame_cnt + 1'd1;
        if(frame_cnt == 2'd1)//VGA 上电后的第3帧开始读FIFO
            vga_access_allow <= 1;
        else
            vga_access_allow <= vga_access_allow;
    end else begin
        frame_cnt <= frame_cnt;
    end
end

defparam dcfifo_input_0.dcfifo_component.lpm_numwords = TWO_FIFO_DEPTH;
wrfifo dcfifo_input_0 //512x16bits
(
    //CMOS--->
    .aclr       (~rst_n),           //异步清零
    .wrclk      (wr_clk),           
    .wrreq      (wr_en),            //写使能信号
    .data       (wr_data),          //数据输入
    .rdusedw    (rdusedw),          //与内部时钟一致
    //--->SDRAM
    .rdclk      (clk),              //读时钟100MHz
    .rdreq      (wr_sdram_allow),   //读使能
    .q          (wr_sdram_data)     //数据输出

);  
wire [15:0]rd_data_wire;
assign rd_data = rd_en? rd_data_wire : 16'd0;//VGA时序必须确保非使能期间数据为0
defparam dcfifo_output_0.dcfifo_component.lpm_numwords = TWO_FIFO_DEPTH;
rdfifo  dcfifo_output_0 //512x16bits//建议设置为队尾一直输出模式
(
    //SDRAM--->
    .aclr       (~rst_n),           //异步清零信号
    .wrclk      (clk),              //写时钟100MHz
    .wrreq      (rd_sdram_allow),   //写使能
    .data       (rd_sdram_data),    //数据输入
    .wrusedw    (wrusedw),          //与内部时钟一致
    //---->VGA
    .rdclk      (rd_clk),           
    .rdreq      (rd_en && vga_access_allow),//读使能
    .q          (rd_data_wire)      //数据输出

);
sdram_core  
sdram_core_0
(
    .clk(clk)           ,
    .clk_ref(clk_ref)   ,
    .rst_n(rst_n)       ,
    
    .wr_addr({wr_bank_addr,wr_row_addr,9'h0})     ,//{bank_addr,row_addr,col_addr}
    .wr_num(TWO_FIFO_DEPTH/10'd2)                       ,
    .wr_request(wr_sdram_request)                 ,    
    .wr_data(wr_sdram_data)                       ,//XXXXXXXX| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |XXXX
    .wr_allow(wr_sdram_allow)                     ,//____|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|_______________
    .wr_busy(wr_sdram_busy)                       ,//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|____
 
    .rd_addr({rd_bank_addr,rd_row_addr,9'h0})     ,//{bank_addr,row_addr,col_addr}
    .rd_num(TWO_FIFO_DEPTH/10'd2)                       ,
    .rd_request(rd_sdram_request)                 ,
    .rd_data(rd_sdram_data)                       ,//XXXX| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |XXXX
    .rd_allow(rd_sdram_allow)                     ,//____|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|_______________
    .rd_busy(rd_sdram_busy)                       ,//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|____
    
    .init_done(sdram_init_done)     ,
    .busy()                         ,
    .state_fly_error()              ,
 
    .sdram_addr(sdram_addr)         ,//(init,read,write)
    .sdram_bkaddr(sdram_bkaddr)     ,//(init,read,write)
    .sdram_data(sdram_data)         ,//only 16bits (read,write)
    .sdram_clk(sdram_clk)           ,
    .sdram_cke(sdram_cke)           ,//always 1
    .sdram_cs_n(sdram_cs_n)         ,//always 0
    .sdram_ras_n(sdram_ras_n)       ,
    .sdram_cas_n(sdram_cas_n)       ,
    .sdram_we_n(sdram_we_n)         ,
    .sdram_dqml(sdram_dqml)         ,//not use,always 0
    .sdram_dqmh(sdram_dqmh)          //not use,always 0
);
endmodule
