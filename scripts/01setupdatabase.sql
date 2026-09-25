-- ============================================================
-- 01 — Banco, schemas lógicos e tabelas relacionais
-- Sistema satélite: Movimentador de Contas e Rastreabilidade
-- SGBD: PostgreSQL 15+ (validado em PostgreSQL 18)
-- Executar como superusuário, conectado a qualquer banco de manutenção:
--   psql -U postgres -h 127.0.0.1 -d postgres -f scripts/01setupdatabase.sql
--
-- Este script apaga somente a base movimentador_contas e os papéis
-- didáticos deste trabalho, depois recria a estrutura.
-- ============================================================

\set ON_ERROR_STOP on
\encoding UTF8

\c postgres

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'movimentador_contas'
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS movimentador_contas;

-- Papéis são objetos do cluster, não do banco. A ordem importa:
-- primeiro os logins (membros), depois os papéis funcionais.
DROP ROLE IF EXISTS usr_operador;
DROP ROLE IF EXISTS usr_atendimento;
DROP ROLE IF EXISTS usr_auditor;
DROP ROLE IF EXISTS usr_intruso;
DROP ROLE IF EXISTS usr_suporte_legado;
DROP ROLE IF EXISTS role_operador_movimentacao;
DROP ROLE IF EXISTS role_atendimento;
DROP ROLE IF EXISTS role_auditor;
DROP ROLE IF EXISTS role_suporte_legado;
DROP ROLE IF EXISTS role_audit_definer;

CREATE DATABASE movimentador_contas;

\c movimentador_contas

ALTER DATABASE movimentador_contas SET timezone TO 'America/Sao_Paulo';
SET timezone TO 'America/Sao_Paulo';

COMMENT ON DATABASE movimentador_contas IS
    'Base dedicada do sistema satelite Movimentador de Contas e Rastreabilidade.';

-- Schemas separam domínio, dado pessoal, operação e (nos scripts seguintes)
-- a superfície LGPD e a trilha. Nada de negócio fica no schema public.
CREATE SCHEMA organizacao;
CREATE SCHEMA identidade;
CREATE SCHEMA contas;

COMMENT ON SCHEMA organizacao IS
    'Setores que originam e recebem contas.';
COMMENT ON SCHEMA identidade IS
    'Colaboradores. Dado pessoal da LGPD; o acesso é concedido por coluna.';
COMMENT ON SCHEMA contas IS
    'Contas em transito e historico de movimentacao. O historico e imutavel.';

REVOKE ALL ON SCHEMA organizacao FROM PUBLIC;
REVOKE ALL ON SCHEMA identidade FROM PUBLIC;
REVOKE ALL ON SCHEMA contas FROM PUBLIC;

CREATE TABLE organizacao.setores (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo      varchar(10)  NOT NULL,
    nome        varchar(80)  NOT NULL,
    descricao   varchar(240) NOT NULL,
    ativo       boolean      NOT NULL DEFAULT true,
    criado_em   timestamptz  NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_setores_codigo UNIQUE (codigo),
    CONSTRAINT ck_setores_codigo_maiusculo CHECK (codigo = upper(codigo))
);

COMMENT ON TABLE organizacao.setores IS
    'Unidades internas responsáveis por originar, receber ou investigar contas.';

CREATE TABLE identidade.colaboradores (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula   varchar(20)  NOT NULL,
    nome        varchar(120) NOT NULL,
    cpf         char(11)     NOT NULL,
    email       varchar(160) NOT NULL,
    setor_id    integer      NOT NULL,
    ativo       boolean      NOT NULL DEFAULT true,
    criado_em   timestamptz  NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_colaboradores_matricula UNIQUE (matricula),
    CONSTRAINT uq_colaboradores_cpf UNIQUE (cpf),
    CONSTRAINT ck_colaboradores_cpf CHECK (cpf ~ '^[0-9]{11}$'),
    CONSTRAINT fk_colaboradores_setor
        FOREIGN KEY (setor_id) REFERENCES organizacao.setores (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT
);

COMMENT ON COLUMN identidade.colaboradores.cpf IS
    'Dado pessoal. Nao e dado sensivel no art. 5 da LGPD, mas exige minimizacao e controle de acesso.';
COMMENT ON COLUMN identidade.colaboradores.email IS
    'Dado pessoal. Oculto para o perfil operacional.';

CREATE TABLE contas.tipos_conta (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo      varchar(20) NOT NULL,
    descricao   varchar(80) NOT NULL,
    CONSTRAINT uq_tipos_conta_codigo UNIQUE (codigo)
);

CREATE TABLE contas.contas (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero           varchar(20)   NOT NULL,
    tipo_id          integer       NOT NULL,
    titular_nome     varchar(120)  NOT NULL,
    titular_cpf      char(11)      NOT NULL,
    titular_email    varchar(160)  NOT NULL,
    setor_origem_id  integer       NOT NULL,
    setor_atual_id   integer       NOT NULL,
    status           varchar(20)   NOT NULL,
    saldo            numeric(15,2) NOT NULL DEFAULT 0,
    aberta_em        timestamptz   NOT NULL DEFAULT clock_timestamp(),
    atualizada_em   timestamptz   NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_contas_numero UNIQUE (numero),
    CONSTRAINT ck_contas_status CHECK (
        status IN ('EM_TRANSITO', 'RECEBIDA', 'BLOQUEADA', 'ENCERRADA')
    ),
    CONSTRAINT ck_contas_saldo CHECK (saldo >= 0),
    CONSTRAINT ck_contas_titular_cpf CHECK (titular_cpf ~ '^[0-9]{11}$'),
    CONSTRAINT fk_contas_tipo
        FOREIGN KEY (tipo_id) REFERENCES contas.tipos_conta (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_contas_origem
        FOREIGN KEY (setor_origem_id) REFERENCES organizacao.setores (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_contas_atual
        FOREIGN KEY (setor_atual_id) REFERENCES organizacao.setores (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
);

COMMENT ON TABLE contas.contas IS
    'Conta em custodia de um setor. CPF, e-mail e saldo sao colunas restritas.';
COMMENT ON COLUMN contas.contas.saldo IS
    'Sigilo financeiro. Nenhum papel operacional recebe esta coluna.';
COMMENT ON COLUMN contas.contas.titular_cpf IS
    'Dado pessoal do titular. Visivel apenas ao dono da tabela e as views mascaradas.';

CREATE TABLE contas.movimentacoes (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    protocolo         varchar(40)  NOT NULL,
    conta_id          integer      NOT NULL,
    setor_origem_id   integer      NOT NULL,
    setor_destino_id  integer      NOT NULL,
    colaborador_id    integer      NOT NULL,
    motivo            varchar(240) NOT NULL,
    ocorrido_em       timestamptz  NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_movimentacoes_protocolo UNIQUE (protocolo),
    CONSTRAINT ck_movimentacoes_setores_distintos CHECK (setor_origem_id <> setor_destino_id),
    CONSTRAINT fk_mov_conta
        FOREIGN KEY (conta_id) REFERENCES contas.contas (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_mov_origem
        FOREIGN KEY (setor_origem_id) REFERENCES organizacao.setores (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_mov_destino
        FOREIGN KEY (setor_destino_id) REFERENCES organizacao.setores (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_mov_colaborador
        FOREIGN KEY (colaborador_id) REFERENCES identidade.colaboradores (id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
);

COMMENT ON TABLE contas.movimentacoes IS
    'Historico de rastreabilidade. Insert-only para os papeis vivos. DELETE e cancelado por trigger no script 04. FKs usam RESTRICT para um apagamento em setor ou conta nao apagar o rastro.';

CREATE INDEX ix_colaboradores_setor ON identidade.colaboradores (setor_id);
CREATE INDEX ix_contas_status ON contas.contas (status);
CREATE INDEX ix_contas_setor_atual ON contas.contas (setor_atual_id);
CREATE INDEX ix_mov_conta ON contas.movimentacoes (conta_id);
CREATE INDEX ix_mov_ocorrido ON contas.movimentacoes (ocorrido_em);

\echo '01setupdatabase.sql concluido: base, schemas e tabelas criados.'
