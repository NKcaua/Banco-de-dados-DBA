-- ============================================================
-- 06 — Consultas forenses
-- Executadas como usr_auditor, sem acesso às tabelas base.
-- A projeção omite o JSON completo de contas para não republicar CPF,
-- e-mail e saldo no relatório. O snapshot integral permanece na trilha.
-- ============================================================

\set ON_ERROR_STOP on
\encoding UTF8
\pset pager off

\c movimentador_contas
RESET SESSION AUTHORIZATION;
SET timezone TO 'America/Sao_Paulo';
SET application_name = 'consulta_forense';
SET SESSION AUTHORIZATION usr_auditor;

SELECT session_user AS investigador, current_user AS papel_efetivo;

\echo ''
\echo '========== F1. Autoria agregada =========='
SELECT
    usuario_banco AS autor,
    tabela,
    operacao,
    bloqueado,
    count(*) AS eventos
FROM auditoria.trilha
GROUP BY usuario_banco, tabela, operacao, bloqueado
ORDER BY usuario_banco, tabela, operacao;

\echo ''
\echo '========== F2. Incidente: tentativa de apagar o historico =========='
SELECT
    id,
    ocorrido_em,
    usuario_banco AS autor,
    endereco_cliente,
    aplicacao,
    operacao,
    chave_registro,
    bloqueado,
    detalhe,
    dados_antigos->>'protocolo' AS protocolo,
    dados_antigos->>'motivo' AS motivo_preservado,
    dados_antigos->>'conta_id' AS conta_id
FROM auditoria.trilha
WHERE bloqueado = true
ORDER BY ocorrido_em, id;

\echo ''
\echo '========== F3. Operacao legitima do operador (OLD/NEW do status) =========='
SELECT
    id,
    ocorrido_em,
    usuario_banco AS autor,
    aplicacao,
    tabela,
    operacao,
    dados_novos->>'protocolo' AS protocolo,
    dados_novos->>'motivo' AS motivo,
    dados_antigos->>'status' AS status_anterior,
    dados_novos->>'status' AS status_novo,
    dados_antigos->>'setor_atual_id' AS setor_anterior,
    dados_novos->>'setor_atual_id' AS setor_novo
FROM auditoria.trilha
WHERE bloqueado = false
ORDER BY ocorrido_em, id;

\echo ''
\echo '========== F4. O protocolo atacado continua visivel na rastreabilidade mascarada =========='
SELECT protocolo, conta, setor_origem, setor_destino, matricula_responsavel, motivo, ocorrido_em
FROM lgpd.vw_rastreabilidade
WHERE protocolo = 'MOV-2026-0001';

\echo ''
\echo '========== F5. Estado atual da conta movimentada de forma valida =========='
SELECT numero, titular, cpf_mascarado, setor_origem, setor_atual, status
FROM lgpd.vw_contas_mascaradas
WHERE numero = '100200-7';

\echo ''
\echo '========== F6. Linha do tempo da investigacao =========='
SELECT
    id,
    to_char(ocorrido_em, 'YYYY-MM-DD HH24:MI:SS') AS ocorrido_em,
    usuario_banco AS autor,
    tabela,
    operacao,
    bloqueado,
    coalesce(
        dados_antigos->>'protocolo',
        dados_novos->>'protocolo',
        dados_novos->>'numero',
        dados_antigos->>'numero'
    ) AS referencia
FROM auditoria.trilha
ORDER BY id;

\echo '06forensicqueries.sql concluido.'
