library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;
use IEEE.std_logic_arith.all;
use work.types.all;

entity cache is

  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    cache_in  : in  cache_in_type;
    cache_out : out cache_out_type;
    sram_out  : in  sram_out_type;
    sram_in   : out sram_in_type);

end entity;

architecture Behavioral of cache is

  type state_type is (NO_OP, FETCH, FLUSH);

  type buf_type is array(0 to 15) of std_logic_vector(31 downto 0);

  type header_line_type is record
    valid : std_logic;
    tag : std_logic_vector(17 downto 0);
  end record;

  type header_type is
    array(0 to 255) of header_line_type;

  type reg_type is record
    state : state_type;

    -- data cache

    header : header_type;

    we     : std_logic;
    tx     : std_logic_vector(31 downto 0);
    tag    : std_logic_vector(17 downto 0);
    index  : std_logic_vector(7 downto 0);
    offset : std_logic_vector(3 downto 0);

    fetch_n : integer range -1 to 15;
    flush_n : integer range -1 to 0;

    sram_addr : std_logic_vector(31 downto 0);
    sram_we   : std_logic;
    sram_re   : std_logic;
    sram_tx   : std_logic_vector(31 downto 0);

    bram_addr : std_logic_vector(11 downto 0);
    bram_di   : std_logic_vector(31 downto 0);
    bram_we   : std_logic;
    bram_re   : std_logic;

    -- instruction cache

    req1 : std_logic;
    addr1 : std_logic_vector(31 downto 0);
  end record;

  constant rzero : reg_type := (
    state     => NO_OP,
    header    => (others => (valid => '0', tag => (others => '0'))),
    we        => '0',
    tx        => (others => '0'),
    tag       => (others => '0'),
    index     => (others => '0'),
    offset    => (others => '0'),
    fetch_n   => -1,
    flush_n   => -1,
    sram_addr => (others => '0'),
    sram_we   => '0',
    sram_re   => '0',
    sram_tx   => (others => '0'),
    bram_addr => (others => '0'),
    bram_di   => (others => '0'),
    bram_we   => '0',
    bram_re   => '0',
    req1 => '0',
    addr1 => (others => '0'));

  signal r, rin : reg_type := rzero;

  signal bram_we   : std_logic := '0';
  signal bram_do   : std_logic_vector(31 downto 0) := (others => '0');
  signal bram_di   : std_logic_vector(31 downto 0) := (others => '0');
  signal bram_addr : std_logic_vector(11 downto 0) := (others => '0');

begin

  blockram_1: entity work.blockram
    generic map (
      dwidth => 32,
      awidth => 12)
    port map (
      clk  => clk,
      we   => bram_we,
      di   => bram_di,
      do   => bram_do,
      addr => bram_addr);

  comb : process(r, cache_in, sram_out)
    variable v : reg_type;
    variable v_hazard : std_logic;
    variable v_hazard2 : std_logic;
    variable v_inst : std_logic_vector(31 downto 0);
  begin
    v := r;

    -- data cache

    v.bram_addr := (others => '0');
    v.sram_addr := (others => '0');
    v.bram_we := '0';
    v.sram_we := '0';
    v.sram_re := '0';

    case r.state is
      when NO_OP =>

        if cache_in.re = '1' or cache_in.we = '1' then

          v.we     := cache_in.we;
          v.tx     := cache_in.val;
          v.tag    := cache_in.addr(31 downto 14);
          v.index  := cache_in.addr(13 downto 6);
          v.offset := cache_in.addr(5 downto 2);

          if not (r.header(conv_integer(v.index)).valid = '1' and r.header(conv_integer(v.index)).tag = v.tag) then
            v.header(conv_integer(v.index)).valid := '0';
            v.sram_addr := v.tag & v.index & "0000" & "00";
            v.sram_re := '1';
            v.fetch_n := -1;
            v.state := FETCH;
          elsif cache_in.we = '1' then
            v.sram_we := '1';
            v.sram_addr := cache_in.addr;
            v.sram_tx := cache_in.val;
            v.flush_n := -1;
            v.state := FLUSH;
          else
            v.bram_addr := v.index & v.offset;
          end if;

        end if;

      when FETCH =>

        case r.fetch_n is
          when -1 =>
            v.sram_addr := r.sram_addr + 4;
            v.sram_re := '1';
            v.fetch_n := 0;
          when 0 to 13 =>
            v.sram_addr := r.sram_addr + 4;
            v.sram_re := '1';
            v.bram_addr := r.index & conv_std_logic_vector(r.fetch_n, 4);
            v.bram_we := '1';
            v.bram_di := sram_out.rx;
            v.fetch_n := r.fetch_n + 1;
          when 14 =>
            v.bram_addr := r.index & conv_std_logic_vector(r.fetch_n, 4);
            v.bram_we := '1';
            v.bram_di := sram_out.rx;
            v.fetch_n := 15;
          when 15 =>
            v.header(conv_integer(r.index)).valid := '1';
            v.header(conv_integer(r.index)).tag := r.tag;
            v.bram_addr := r.index & conv_std_logic_vector(r.fetch_n, 4);
            v.bram_we := '1';
            v.bram_di := sram_out.rx;

            if r.we = '1' then
              v.sram_we := '1';
              v.sram_addr := r.tag & r.index & r.offset & "00";
              v.sram_tx := r.tx;
              v.flush_n := -1;
              v.state := FLUSH;
            else
              v.state := NO_OP;
            end if;
          when others =>
            assert false;
            v.state := NO_OP;
        end case;

      when FLUSH =>

        case r.flush_n is
          when -1 =>
            v.flush_n := 0;
          when 0 =>
            v.bram_addr := r.index & r.offset;
            v.bram_we := '1';
            v.bram_di := r.tx;

            v.state := NO_OP;
          when others =>
            assert false report "cache: invalid value stored in flush_n";
            v.state := NO_OP;
        end case;

      when others =>
        assert false;
        v.state := NO_OP;
    end case;

    if v.state = NO_OP then
      v_hazard := '0';
    else
      v_hazard := '1';
    end if;


    -- instruction cache

    v_inst := sram_out.rx;

    if r.req1 = '1' and r.addr1 = cache_in.addr2 then
      v_hazard2 := '0';
    else
      v_hazard2 := '1';
    end if;

    if v.sram_re = '0' and v.sram_we = '0' then
      v.req1 := '1';
      v.addr1 := cache_in.addr2;
      -- request to sram
      v.sram_addr := cache_in.addr2;
      v.sram_re := '1';
    else
      v.req1 := '0';
    end if;

    -- end

    rin <= v;

    cache_out.stall <= v_hazard;
    cache_out.rx    <= bram_do;
    cache_out.stall2 <= v_hazard2;
    cache_out.rx2   <= v_inst;
    sram_in.addr    <= v.sram_addr;
    sram_in.tx      <= v.sram_tx;
    sram_in.we      <= v.sram_we;
    sram_in.re      <= '1';
    bram_we         <= v.bram_we;
    bram_addr       <= v.bram_addr;
    bram_di         <= v.bram_di;
  end process;

  regs : process(clk, rst)
  begin
    if rst = '1' then
      r <= rzero;
    elsif rising_edge(clk) then
      r <= rin;
    end if;
  end process;

end architecture;
