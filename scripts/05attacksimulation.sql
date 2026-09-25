-- ============================================================
-- 05 — Bateria ofensiva
--
-- Erros são esperados. ON_ERROR_STOP fica desligado de propósito:
-- a bateria continua depois de cada bloqueio do SGBD.
--
-- Cada tentativa começa com RESET + SET SESSION AUTHORIZATION para
-- a autoria gravada em session_user ser o login testado, não o superusuário.
-- ============================================================

\set ON_ERROR_STOP off
\encoding UTF8
\pset pager off
\set VERBOSITY verbose

\c movimentador_contas
SET timezone TO 'America/Sao_Paulo';
SET application_name = 'bateria_ofensiva';

\echo ''
\echo '========== T01 intruso le contas.contas (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_intruso;
SELECT session_user AS usuario_da_tentativa;
SELECT numero, titular_cpf FROM contas.contas;

\echo ''
\echo '========== T02 intruso le a view LGPD (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_intruso;
SELECT numero, cpf_mascarado FROM lgpd.vw_contas_mascaradas;

\echo ''
\echo '========== T03 operador le apenas numero e status (esperado: sucesso) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
SELECT session_user AS usuario_da_tentativa;
SELECT numero, status FROM contas.contas ORDER BY numero;

\echo ''
\echo '========== T04 operador le CPF, e-mail e saldo (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
SELECT numero, titular_cpf, titular_email, saldo FROM contas.contas;

\echo ''
\echo '========== T05 operador le CPF e e-mail do colaborador (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
SELECT matricula, cpf, email FROM identidade.colaboradores;

\echo ''
\echo '========== T06 operador faz SELECT * em contas (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
SELECT * FROM contas.contas;

\echo ''
\echo '========== T07 operador apaga historico (esperado: 42501, sem DELETE) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
DELETE FROM contas.movimentacoes WHERE protocolo = 'MOV-2026-0001';

\echo ''
\echo '========== T08 operador esvazia historico com TRUNCATE (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
TRUNCATE TABLE contas.movimentacoes;

\echo ''
\echo '========== T09 atendimento le a tabela base (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_atendimento;
SELECT numero, titular_cpf, saldo FROM contas.contas;

\echo ''
\echo '========== T10 atendimento altera status (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_atendimento;
UPDATE contas.contas SET status = 'ENCERRADA' WHERE numero = '100100-1';

\echo ''
\echo '========== T11 atendimento consulta a view mascarada (esperado: sucesso, sem saldo e sem CPF integral) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_atendimento;
SELECT numero, titular, cpf_mascarado, email_mascarado, setor_atual, status
FROM lgpd.vw_contas_mascaradas
ORDER BY numero;

\echo ''
\echo '========== T12 suporte legado apaga MOV-2026-0001 (esperado: DELETE 0, aviso, linha permanece, incidente na trilha) =========='
RESET SESSION AUTHORIZATION;
SET application_name = 'cliente_suporte_legado';
SET SESSION AUTHORIZATION usr_suporte_legado;
SELECT session_user AS usuario_da_tentativa;
DELETE FROM contas.movimentacoes WHERE protocolo = 'MOV-2026-0001';
SELECT protocolo, motivo
FROM contas.movimentacoes
WHERE protocolo = 'MOV-2026-0001';

\echo ''
\echo '========== T13 suporte legado altera motivo do historico (esperado: 42501, sem UPDATE) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_suporte_legado;
UPDATE contas.movimentacoes
SET motivo = 'historico adulterado'
WHERE protocolo = 'MOV-2026-0001';

\echo ''
\echo '========== T14 sessao administrativa adultera a trilha (esperado: AUDITORIA-IMUTAVEL) =========='
RESET SESSION AUTHORIZATION;
SET application_name = 'bateria_ofensiva';
SELECT session_user AS usuario_da_tentativa;
UPDATE auditoria.trilha
SET detalhe = 'adulteracao'
WHERE bloqueado = true;

\echo ''
\echo '========== T15 sessao administrativa apaga a trilha (esperado: AUDITORIA-IMUTAVEL) =========='
RESET SESSION AUTHORIZATION;
DELETE FROM auditoria.trilha;

\echo ''
\echo '========== T16 sessao administrativa faz TRUNCATE do historico (esperado: RASTREABILIDADE) =========='
RESET SESSION AUTHORIZATION;
TRUNCATE TABLE contas.movimentacoes;
SELECT count(*) AS movimentacoes_preservadas FROM contas.movimentacoes;

\echo ''
\echo '========== T17 auditor tenta apagar a trilha (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_auditor;
DELETE FROM auditoria.trilha;

\echo ''
\echo '========== T18 operador consulta a trilha (esperado: 42501) =========='
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION usr_operador;
SELECT id, usuario_banco, operacao FROM auditoria.trilha;

\echo ''
\echo '========== T19 operador executa remessa valida da conta 100200-7 (esperado: INSERT 1 e UPDATE 1) =========='
RESET SESSION AUTHORIZATION;
SET application_name = 'app_movimentador';
SET SESSION AUTHORIZATION usr_operador;
SELECT session_user AS usuario_da_tentativa;
INSERT INTO contas.movimentacoes (
    protocolo, conta_id, setor_origem_id, setor_destino_id, colaborador_id, motivo
)
SELECT
    'MOV-VALIDO-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
    c.id,
    c.setor_atual_id,
    dest.id,
    col.id,
    'Remessa valida da conta 100200-7 da Tesouraria para Operacoes'
FROM contas.contas c
JOIN organizacao.setores dest ON dest.codigo = 'OPE'
JOIN identidade.colaboradores col ON col.matricula = '1002'
WHERE c.numero = '100200-7'
  AND c.setor_atual_id <> dest.id;

UPDATE contas.contas
SET status = 'EM_TRANSITO',
    setor_atual_id = (SELECT id FROM organizacao.setores WHERE codigo = 'OPE'),
    atualizada_em = clock_timestamp()
WHERE numero = '100200-7';

SELECT numero, status
FROM lgpd.vw_contas_mascaradas
WHERE numero = '100200-7';

\echo ''
\echo '========== Conferencia final da bateria, de volta ao superusuario =========='
RESET SESSION AUTHORIZATION;
SELECT protocolo
FROM contas.movimentacoes
WHERE protocolo IN ('MOV-2026-0001', 'MOV-2026-0002', 'MOV-2026-0003', 'MOV-2026-0004', 'MOV-2026-0005')
ORDER BY protocolo;
SELECT count(*) AS eventos_na_trilha FROM auditoria.trilha;

\echo '05attacksimulation.sql concluido.'
