-- ============================================================
-- 02 — Carga inicial
-- Setores, colaboradores, tipos, contas em trânsito e histórico.
-- CPFs e e-mails são fictícios (domínio .invalid, reservado pela RFC 2606).
-- Os dígitos verificadores dos CPFs são válidos, mas não identificam pessoas reais.
-- ============================================================

\set ON_ERROR_STOP on
\encoding UTF8
\c movimentador_contas

SET timezone TO 'America/Sao_Paulo';

INSERT INTO organizacao.setores (codigo, nome, descricao) VALUES
    ('TES', 'Tesouraria',          'Custodia e liquidacao das contas recebidas'),
    ('OPE', 'Operacoes',           'Executa o deslocamento das contas entre setores'),
    ('CAR', 'Contas a Receber',    'Origina contas de clientes em aberto'),
    ('ATD', 'Atendimento',         'Registra a demanda do titular'),
    ('CPL', 'Compliance',          'Analisa contas bloqueadas ou suspeitas'),
    ('AUD', 'Auditoria Interna',   'Investiga a rastreabilidade sem alterar o operacional');

INSERT INTO identidade.colaboradores (matricula, nome, cpf, email, setor_id)
SELECT v.matricula, v.nome, v.cpf, v.email, s.id
FROM (VALUES
    ('1001', 'Ana Ribeiro',   '39053344705', 'ana.ribeiro@exemplo.invalid',   'ATD'),
    ('1002', 'Bruno Costa',   '52998224725', 'bruno.costa@exemplo.invalid',   'OPE'),
    ('1003', 'Carla Mendes',  '11144477735', 'carla.mendes@exemplo.invalid',  'CAR'),
    ('1004', 'Diego Alves',   '85351346036', 'diego.alves@exemplo.invalid',   'CPL'),
    ('1005', 'Elena Duarte',  '12345678909', 'elena.duarte@exemplo.invalid',  'AUD'),
    ('1006', 'Fabio Nunes',   '71402538030', 'fabio.nunes@exemplo.invalid',   'TES')
) AS v(matricula, nome, cpf, email, setor_codigo)
JOIN organizacao.setores s ON s.codigo = v.setor_codigo;

INSERT INTO contas.tipos_conta (codigo, descricao) VALUES
    ('CC', 'Conta corrente'),
    ('PP', 'Poupanca'),
    ('PG', 'Conta pagamento');

INSERT INTO contas.contas (
    numero, tipo_id, titular_nome, titular_cpf, titular_email,
    setor_origem_id, setor_atual_id, status, saldo
)
SELECT
    v.numero,
    t.id,
    v.titular_nome,
    v.titular_cpf,
    v.titular_email,
    origem.id,
    atual.id,
    v.status,
    v.saldo
FROM (VALUES
    ('100100-1', 'CC', 'Helena Prado',    '45678912364', 'helena.prado@exemplo.invalid',    'CAR', 'OPE', 'EM_TRANSITO', 1520.45),
    ('100200-7', 'CC', 'Igor Santana',    '32165498791', 'igor.santana@exemplo.invalid',    'ATD', 'TES', 'RECEBIDA',     300.00),
    ('100300-4', 'PP', 'Julia Ferraz',    '98765432100', 'julia.ferraz@exemplo.invalid',    'OPE', 'CPL', 'EM_TRANSITO',   890.10),
    ('100400-2', 'PG', 'Laura Pires',     '13579246828', 'laura.pires@exemplo.invalid',     'CAR', 'CAR', 'RECEBIDA',       50.00),
    ('100500-9', 'CC', 'Marcos Teixeira', '24681357928', 'marcos.teixeira@exemplo.invalid', 'TES', 'CPL', 'BLOQUEADA',   12000.00),
    ('100600-5', 'PP', 'Nina Barbosa',    '10293847541', 'nina.barbosa@exemplo.invalid',    'OPE', 'AUD', 'EM_TRANSITO',   430.75)
) AS v(numero, tipo_codigo, titular_nome, titular_cpf, titular_email, origem_codigo, atual_codigo, status, saldo)
JOIN contas.tipos_conta t ON t.codigo = v.tipo_codigo
JOIN organizacao.setores origem ON origem.codigo = v.origem_codigo
JOIN organizacao.setores atual ON atual.codigo = v.atual_codigo;

INSERT INTO contas.movimentacoes (
    protocolo, conta_id, setor_origem_id, setor_destino_id, colaborador_id, motivo
)
SELECT
    v.protocolo,
    c.id,
    origem.id,
    destino.id,
    col.id,
    v.motivo
FROM (VALUES
    ('MOV-2026-0001', '100100-1', 'CAR', 'OPE', '1003', 'Encaminhamento da conta para operacoes'),
    ('MOV-2026-0002', '100200-7', 'ATD', 'TES', '1001', 'Abertura encaminhada a tesouraria'),
    ('MOV-2026-0003', '100300-4', 'OPE', 'CPL', '1002', 'Envio para analise de compliance'),
    ('MOV-2026-0004', '100500-9', 'TES', 'CPL', '1006', 'Conta bloqueada encaminhada ao compliance'),
    ('MOV-2026-0005', '100600-5', 'OPE', 'AUD', '1004', 'Conta remetida para auditoria interna')
) AS v(protocolo, numero, origem_codigo, destino_codigo, matricula, motivo)
JOIN contas.contas c ON c.numero = v.numero
JOIN organizacao.setores origem ON origem.codigo = v.origem_codigo
JOIN organizacao.setores destino ON destino.codigo = v.destino_codigo
JOIN identidade.colaboradores col ON col.matricula = v.matricula;

\echo '02seeddata.sql concluido: carga inicial aplicada.'
