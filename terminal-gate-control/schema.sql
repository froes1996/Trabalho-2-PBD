DROP DATABASE IF EXISTS terminal_logistico;
CREATE DATABASE terminal_logistico;
\c terminal_logistico

CREATE TABLE transportadoras (
    id SERIAL PRIMARY KEY,
    razao_social VARCHAR(150) NOT NULL,
    cnpj VARCHAR(18) NOT NULL UNIQUE,
    ativo BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE veiculos (
    id SERIAL PRIMARY KEY,
    placa_cavalo VARCHAR(10) NOT NULL UNIQUE,
    placa_carreta VARCHAR(10) NOT NULL,
    tara_kg NUMERIC(10, 2) NOT NULL CHECK (tara_kg > 0),
    pbtc_maximo_kg NUMERIC(10, 2) NOT NULL,
    transportadora_id INT NOT NULL REFERENCES transportadoras(id) ON DELETE RESTRICT,
    CONSTRAINT chk_pbtc_maior_que_tara CHECK (pbtc_maximo_kg > tara_kg)
);

CREATE TABLE blocos_patio (
    id SERIAL PRIMARY KEY,
    codigo_bloco VARCHAR(20) NOT NULL UNIQUE,
    tipo_suportado VARCHAR(10) NOT NULL CHECK (tipo_suportado IN ('DRY', 'REEFER', 'IMO')),
    capacidade_maxima INT NOT NULL CHECK (capacidade_maxima > 0),
    ocupacao_atual INT NOT NULL DEFAULT 0,
    CONSTRAINT chk_ocupacao_limites CHECK (ocupacao_atual >= 0 AND ocupacao_atual <= capacidade_maxima)
);

CREATE TABLE containers (
    id SERIAL PRIMARY KEY,
    numero_iso VARCHAR(15) NOT NULL UNIQUE,
    tipo VARCHAR(10) NOT NULL CHECK (tipo IN ('DRY', 'REEFER', 'IMO')),
    tara_kg NUMERIC(10, 2) NOT NULL CHECK (tara_kg > 0),
    status VARCHAR(20) NOT NULL DEFAULT 'AGUARDANDO_GATE'
        CHECK (status IN ('AGUARDANDO_GATE', 'NO_PATIO', 'EM_INSPECAO', 'EXPEDIDO')),
    bloco_id INT NULL REFERENCES blocos_patio(id) ON DELETE RESTRICT,
    data_entrada TIMESTAMP NULL,
    CONSTRAINT chk_coerencia_status_bloco CHECK (
        (status IN ('AGUARDANDO_GATE', 'EXPEDIDO') AND bloco_id IS NULL)
        OR
        (status IN ('NO_PATIO', 'EM_INSPECAO') AND bloco_id IS NOT NULL)
    )
);

CREATE TABLE ordens_pesagem (
    id SERIAL PRIMARY KEY,
    protocolo VARCHAR(25) NOT NULL UNIQUE,
    veiculo_id INT NOT NULL REFERENCES veiculos(id) ON DELETE RESTRICT,
    container_id INT NOT NULL REFERENCES containers(id) ON DELETE RESTRICT,
    tipo_operacao VARCHAR(15) NOT NULL CHECK (tipo_operacao IN ('DESCARGA', 'EMBARQUE')),
    peso_entrada_kg NUMERIC(10, 2) NOT NULL CHECK (peso_entrada_kg > 0),
    peso_saida_kg NUMERIC(10, 2) NULL CHECK (peso_saida_kg IS NULL OR peso_saida_kg > 0),
    peso_liquido_kg NUMERIC(10, 2) NULL CHECK (peso_liquido_kg IS NULL OR peso_liquido_kg >= 0),
    status_ordem VARCHAR(15) NOT NULL DEFAULT 'ABERTA'
        CHECK (status_ordem IN ('ABERTA', 'CONCLUIDA', 'CANCELADA')),
    data_entrada TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    data_saida TIMESTAMP NULL
);

CREATE TABLE auditoria_containers (
    id SERIAL PRIMARY KEY,
    container_id INT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
    evento VARCHAR(40) NOT NULL,
    status_anterior VARCHAR(20),
    status_novo VARCHAR(20),
    bloco_anterior_id INT NULL REFERENCES blocos_patio(id),
    bloco_novo_id INT NULL REFERENCES blocos_patio(id),
    registrado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    observacao TEXT
);


CREATE OR REPLACE FUNCTION fn_calcular_peso_liquido(p_ordem_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_peso_entrada NUMERIC(10, 2);
    v_peso_saida NUMERIC(10, 2);
    v_tara_veiculo NUMERIC(10, 2);
    v_tara_container NUMERIC(10, 2);
    v_peso_liquido NUMERIC(10, 2);
BEGIN
    SELECT o.peso_entrada_kg, o.peso_saida_kg, v.tara_kg, c.tara_kg
      INTO v_peso_entrada, v_peso_saida, v_tara_veiculo, v_tara_container
      FROM ordens_pesagem o
      JOIN veiculos v ON v.id = o.veiculo_id
      JOIN containers c ON c.id = o.container_id
     WHERE o.id = p_ordem_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ordem de pesagem % não encontrada.', p_ordem_id;
    END IF;

    IF v_peso_saida IS NOT NULL THEN
        v_peso_liquido := ABS(v_peso_saida - v_peso_entrada) - v_tara_container;
    ELSE
        v_peso_liquido := v_peso_entrada - v_tara_veiculo - v_tara_container;
    END IF;

    RETURN GREATEST(ROUND(v_peso_liquido, 2), 0);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_indicadores_ocupacao_patio()
RETURNS TABLE (
    bloco_id INT,
    codigo_bloco VARCHAR,
    tipo_suportado VARCHAR,
    capacidade_maxima INT,
    ocupacao_atual INT,
    vagas_disponiveis INT,
    taxa_ocupacao_pct NUMERIC,
    media_dias_patio NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        b.id AS bloco_id,
        b.codigo_bloco,
        b.tipo_suportado,
        b.capacidade_maxima,
        b.ocupacao_atual,
        (b.capacidade_maxima - b.ocupacao_atual) AS vagas_disponiveis,
        ROUND((b.ocupacao_atual::NUMERIC / b.capacidade_maxima::NUMERIC) * 100, 1) AS taxa_ocupacao_pct,
        COALESCE(
            ROUND(AVG(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - c.data_entrada)) / 86400.0)::NUMERIC, 1),
            0.0
        ) AS media_dias_patio
    FROM blocos_patio b
    LEFT JOIN containers c
           ON c.bloco_id = b.id
          AND c.status IN ('NO_PATIO', 'EM_INSPECAO')
    GROUP BY b.id, b.codigo_bloco, b.tipo_suportado, b.capacidade_maxima, b.ocupacao_atual
    ORDER BY b.codigo_bloco;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION fn_trg_validar_limite_peso()
RETURNS TRIGGER AS $$
DECLARE
    v_pbtc_maximo NUMERIC(10, 2);
    v_placa VARCHAR(10);
BEGIN
    SELECT pbtc_maximo_kg, placa_cavalo
      INTO v_pbtc_maximo, v_placa
      FROM veiculos
     WHERE id = NEW.veiculo_id;

    IF NEW.peso_entrada_kg > v_pbtc_maximo THEN
        RAISE EXCEPTION 'BLOQUEIO DE BALANÇA: Peso de entrada (% kg) excede o PBTC máximo (% kg) do veículo %.',
            NEW.peso_entrada_kg, v_pbtc_maximo, v_placa;
    END IF;

    IF NEW.peso_saida_kg IS NOT NULL AND NEW.peso_saida_kg > v_pbtc_maximo THEN
        RAISE EXCEPTION 'BLOQUEIO DE BALANÇA: Peso de saída (% kg) excede o PBTC máximo (% kg) do veículo %.',
            NEW.peso_saida_kg, v_pbtc_maximo, v_placa;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validar_limite_peso
BEFORE INSERT OR UPDATE OF peso_entrada_kg, peso_saida_kg ON ordens_pesagem
FOR EACH ROW
EXECUTE FUNCTION fn_trg_validar_limite_peso();

CREATE OR REPLACE FUNCTION fn_trg_auditoria_movimentacao_container()
RETURNS TRIGGER AS $$
DECLARE
    v_evento VARCHAR(40);
    v_obs TEXT;
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status OR OLD.bloco_id IS DISTINCT FROM NEW.bloco_id THEN
        IF OLD.status = 'AGUARDANDO_GATE' AND NEW.status = 'NO_PATIO' THEN
            v_evento := 'ENTRADA_PATIO';
            v_obs := 'Contêiner recebido pelo Gate e alocado no pátio.';
        ELSIF OLD.bloco_id IS NOT NULL AND NEW.bloco_id IS NOT NULL AND OLD.bloco_id <> NEW.bloco_id THEN
            v_evento := 'REMANEJAMENTO_BLOCO';
            v_obs := 'Transferência interna de posicionamento entre blocos.';
        ELSIF NEW.status = 'EM_INSPECAO' THEN
            v_evento := 'ENVIO_INSPECAO';
            v_obs := 'Contêiner posicionado para vistoria/conferência.';
        ELSIF OLD.status = 'EM_INSPECAO' AND NEW.status = 'NO_PATIO' THEN
            v_evento := 'LIBERACAO_INSPECAO';
            v_obs := 'Vistoria concluída; contêiner liberado no bloco.';
        ELSIF NEW.status = 'EXPEDIDO' THEN
            v_evento := 'SAIDA_TERMINAL';
            v_obs := 'Contêiner embarcado e expedido pelo Gate de saída.';
        ELSE
            v_evento := 'ATUALIZACAO_STATUS';
            v_obs := 'Alteração de estado operacional do contêiner.';
        END IF;

        INSERT INTO auditoria_containers (
            container_id, evento, status_anterior, status_novo,
            bloco_anterior_id, bloco_novo_id, observacao
        ) VALUES (
            NEW.id, v_evento, OLD.status, NEW.status,
            OLD.bloco_id, NEW.bloco_id, v_obs
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auditoria_movimentacao_container
AFTER UPDATE OF status, bloco_id ON containers
FOR EACH ROW
EXECUTE FUNCTION fn_trg_auditoria_movimentacao_container();


CREATE OR REPLACE PROCEDURE sp_alocar_container_patio(
    p_container_id INT,
    p_bloco_id INT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_tipo_container VARCHAR(10);
    v_status_atual VARCHAR(20);
    v_bloco_atual INT;
    v_tipo_bloco VARCHAR(10);
    v_capacidade INT;
    v_ocupacao INT;
BEGIN
    SELECT tipo, status, bloco_id
      INTO v_tipo_container, v_status_atual, v_bloco_atual
      FROM containers
     WHERE id = p_container_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Contêiner ID % não encontrado.', p_container_id;
    END IF;

    IF v_status_atual = 'EXPEDIDO' THEN
        RAISE EXCEPTION 'Operação negada: o contêiner já foi expedido do terminal.';
    END IF;

    IF v_bloco_atual IS NOT DISTINCT FROM p_bloco_id THEN
        RAISE EXCEPTION 'O contêiner já está alocado neste mesmo bloco.';
    END IF;

    SELECT tipo_suportado, capacidade_maxima, ocupacao_atual
      INTO v_tipo_bloco, v_capacidade, v_ocupacao
      FROM blocos_patio
     WHERE id = p_bloco_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bloco de pátio ID % não encontrado.', p_bloco_id;
    END IF;

    IF v_tipo_container <> v_tipo_bloco THEN
        RAISE EXCEPTION 'Incompatibilidade operacional: contêiner % não pode ser alocado em bloco %.',
            v_tipo_container, v_tipo_bloco;
    END IF;

    IF v_ocupacao >= v_capacidade THEN
        RAISE EXCEPTION 'Bloco lotado (% / % vagas ocupadas). Escolha outro bloco.',
            v_ocupacao, v_capacidade;
    END IF;

    IF v_bloco_atual IS NOT NULL THEN
        UPDATE blocos_patio
           SET ocupacao_atual = ocupacao_atual - 1
         WHERE id = v_bloco_atual;
    END IF;

    UPDATE blocos_patio
       SET ocupacao_atual = ocupacao_atual + 1
     WHERE id = p_bloco_id;

    UPDATE containers
       SET bloco_id = p_bloco_id,
           status = 'NO_PATIO',
           data_entrada = COALESCE(data_entrada, CURRENT_TIMESTAMP)
     WHERE id = p_container_id;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_finalizar_pesagem_saida(
    p_ordem_id INT,
    p_peso_saida_kg NUMERIC
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status_ordem VARCHAR(15);
    v_tipo_operacao VARCHAR(15);
    v_container_id INT;
    v_bloco_id INT;
    v_peso_liquido NUMERIC(10, 2);
BEGIN
    SELECT status_ordem, tipo_operacao, container_id
      INTO v_status_ordem, v_tipo_operacao, v_container_id
      FROM ordens_pesagem
     WHERE id = p_ordem_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ordem de pesagem ID % não encontrada.', p_ordem_id;
    END IF;

    IF v_status_ordem <> 'ABERTA' THEN
        RAISE EXCEPTION 'A ordem de pesagem já está encerrada (status: %).', v_status_ordem;
    END IF;

    UPDATE ordens_pesagem
       SET peso_saida_kg = p_peso_saida_kg,
           data_saida = CURRENT_TIMESTAMP,
           status_ordem = 'CONCLUIDA'
     WHERE id = p_ordem_id;

    v_peso_liquido := fn_calcular_peso_liquido(p_ordem_id);

    UPDATE ordens_pesagem
       SET peso_liquido_kg = v_peso_liquido
     WHERE id = p_ordem_id;

    IF v_tipo_operacao = 'EMBARQUE' THEN
        SELECT bloco_id
          INTO v_bloco_id
          FROM containers
         WHERE id = v_container_id
           FOR UPDATE;

        IF v_bloco_id IS NOT NULL THEN
            UPDATE blocos_patio
               SET ocupacao_atual = ocupacao_atual - 1
             WHERE id = v_bloco_id;
        END IF;

        UPDATE containers
           SET status = 'EXPEDIDO',
               bloco_id = NULL
         WHERE id = v_container_id;
    END IF;
END;
$$;


INSERT INTO transportadoras (razao_social, cnpj) VALUES
('Transcontinental Logística S/A', '12.345.678/0001-90'),
('Expresso Sul-Rio-Grandense Ltda', '98.765.432/0001-10'),
('Rodoviário Atlântico Sul S/A', '45.123.789/0001-55');

INSERT INTO veiculos (placa_cavalo, placa_carreta, tara_kg, pbtc_maximo_kg, transportadora_id) VALUES
('IXX-4A12', 'IYY-9B88', 15200.00, 45000.00, 1),
('JAA-7C34', 'JBB-1D22', 16000.00, 53000.00, 1),
('KCC-2E90', 'KDD-5F44', 14800.00, 41500.00, 2),
('LEE-8G11', 'LFF-3H77', 16500.00, 57000.00, 3);

INSERT INTO blocos_patio (codigo_bloco, tipo_suportado, capacidade_maxima) VALUES
('BLOCO-A1', 'DRY', 20),
('BLOCO-B1', 'REEFER', 10),
('BLOCO-C1', 'IMO', 6);

INSERT INTO containers (numero_iso, tipo, tara_kg, status) VALUES
('MSKU9045123', 'DRY', 3800.00, 'AGUARDANDO_GATE'),
('CMAU4412890', 'DRY', 3750.00, 'AGUARDANDO_GATE'),
('HLXU7781234', 'REEFER', 4650.00, 'AGUARDANDO_GATE'),
('TRLU5520987', 'IMO', 3900.00, 'AGUARDANDO_GATE'),
('SUDU8834120', 'DRY', 3820.00, 'AGUARDANDO_GATE');

CALL sp_alocar_container_patio(1, 1);
CALL sp_alocar_container_patio(3, 2);
CALL sp_alocar_container_patio(4, 3);

UPDATE containers SET data_entrada = CURRENT_TIMESTAMP - INTERVAL '3 days' WHERE id = 1;

INSERT INTO ordens_pesagem (protocolo, veiculo_id, container_id, tipo_operacao, peso_entrada_kg)
VALUES ('BAL-2026-0001', 1, 1, 'EMBARQUE', 15250.00);