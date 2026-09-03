library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Entidade padronizada para comparação direta de interface
entity multiplier_booth is
    generic(
        N : integer := 32 -- Largura dos operandos (32 bits, idêntico ao serial)
    );
    port(
        clock   : in  std_logic;                       -- Sinal de clock
        start   : in  std_logic;                       -- Reset/Start assíncrono (ativo em '1')
        Mpland  : in  std_logic_vector(N-1 downto 0);  -- Multiplicando (A)
        Mplier  : in  std_logic_vector(N-1 downto 0);  -- Multiplicador (B)
        endop   : out std_logic;                       -- Pulso de 1 ciclo indicando término
        Product : out std_logic_vector(2*N-1 downto 0) -- Resultado final (64 bits)
    );
end multiplier_booth;

architecture booth4 of multiplier_booth is

    -- DIFERENÇA DO SERIAL: Constantes ajustadas para o algoritmo Booth Radix-4 com sinal.
    constant W     : integer := N + 2;          -- 34 bits: Extensão de zeros para tratar MULTU como positivo em complemento de 2
    constant ITER  : integer := W / 2;          -- 17 iterações: Processa 2 bits/ciclo (o serial precisa de 32 iterações)
    constant ACC_W : integer := W + 2;          -- 36 bits: Acumulador com margem de segurança contra overflow
    constant TOT   : integer := ACC_W + W + 1;  -- 71 bits: Registrador gigante [Acumulador(36) | Mplier(34) | Bit_ficticio(1)]

    type state_t is (initialize, iterate, finish, endm);
    signal EA : state_t;

    signal regP  : signed(TOT-1 downto 0);    -- Registrador combinado de deslocamento e acumulador
    signal regB  : signed(ACC_W-1 downto 0);  -- Armazena o multiplicando estendido
    
    -- BASE IGUALADA: Contador delimitado a 5 bits (0 a 18). 
    -- Garante que ambos os módulos usem a mesma quantidade enxuta de Flip-Flops para controle.
    signal count : integer range 0 to ITER+1;

    -- Sinais combinacionais do Booth
    signal acc    : signed(ACC_W-1 downto 0);     -- Fatia superior de regP (Acumulador)
    signal term   : signed(ACC_W-1 downto 0);     -- Valor selecionado pelo Mux 5-para-1
    signal accsum : signed(ACC_W-1 downto 0);     -- Resultado da soma/subtração parcial
    signal window : std_logic_vector(2 downto 0); -- Janela de 3 bits lida a cada ciclo

begin
    -- Extrai a parte alta de regP para ser o acumulador
    acc <= regP(TOT-1 downto W+1);

    -- DIFERENÇA DO SERIAL: Lê os 3 bits inferiores de regP em paralelo.
    -- O serial lê apenas 1 bit de cada vez.
    window <= std_logic_vector(regP(2 downto 0));

    -- RECODIFICAÇÃO DE BOOTH (Mux 5-para-1 Combinacional)
    -- DIFERENÇA DO SERIAL: Decide em 1 ciclo se soma, subtrai ou multiplica por 2 (shift_left).
    -- Operações como shift_left(regB,1) são apenas rotação de fios no FPGA (custo 0 de LUTs).
    with window select
        term <= (others => '0')        when "000",   --  0
                regB                   when "001",   -- +1 (Soma Mpland)
                regB                   when "010",   -- +1 (Soma Mpland)
                shift_left(regB, 1)    when "011",   -- +2 (Soma Mpland * 2)
                -shift_left(regB, 1)   when "100",   -- -2 (Subtrai Mpland * 2)
                -regB                  when "101",   -- -1 (Subtrai Mpland)
                -regB                  when "110",   -- -1 (Subtrai Mpland)
                (others => '0')        when others;  --  0

    -- Somador/Subtrator parcial em lógica combinacional
    accsum <= acc + term;

    ----------------------------------------------------------------------
    -- Registradores e Fluxo de Dados (Datapath)
    ----------------------------------------------------------------------
    process(start, clock)
    begin
        if start = '1' then
            -- Reset assíncrono: Limpa todos os registradores
            regP    <= (others => '0');
            regB    <= (others => '0');
            count   <= 0;
            endop   <= '0';
            Product <= (others => '0');
        elsif rising_edge(clock) then
            case EA is
                when initialize =>
                    -- Prepara os operandos adicionando o bit '0' na frente (unsigned para signed positivo)
                    regB <= resize(signed('0' & Mpland), ACC_W);
                    regP(TOT-1 downto W+1) <= (others => '0');
                    regP(W downto 1)        <= resize(signed('0' & Mplier), W);
                    regP(0)                 <= '0'; -- Bit b(-1) exigido pelo algoritmo
                    count <= 1;

                when iterate =>
                    -- DIFERENÇA CRUCIAL: Executa a SOMA e o SHIFT ARITMÉTICO DUPLO (2 bits à direita)
                    -- tudo dentro do MESMO ciclo de clock! O serial exige estados separados para somar e deslocar.
                    regP <= shift_right(
                              signed(std_logic_vector(accsum) & 
                                     std_logic_vector(regP(W downto 0))), 2);
                    count <= count + 1;

                when finish =>
                    -- Corta os bits de extensão e entrega o resultado final de 64 bits
                    Product <= std_logic_vector(regP(2*N downto 1));
                    endop   <= '1'; -- Emite o sinal de término

                when endm =>
                    endop <= '0';   -- Zera o pulso no ciclo seguinte
            end case;
        end if;
    end process;

    ----------------------------------------------------------------------
    -- Máquina de Estados de Controle (FSM)
    ----------------------------------------------------------------------
    process(start, clock)
    begin
        if start = '1' then
            EA <= initialize;
        elsif rising_edge(clock) then
            case EA is
                when initialize => 
                    EA <= iterate;

                when iterate => 
                    -- DIFERENÇA DO SERIAL: Encerra em 17 ciclos (ITER) em vez de 32 ou 64.
                    if count = ITER then
                        EA <= finish;
                    end if;

                when finish => 
                    EA <= endm;

                when endm => 
                    EA <= endm;
            end case;
        end if;
    end process;

end booth4;