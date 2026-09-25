-- ============================================================
-- 03 — Higienização do PUBLIC, RBAC, menor privilégio e views LGPD
--
-- Papéis (NOLOGIN) separam a função do login.
-- Logins herdam um único papel. usr_intruso não herda nenhum.
-- usr_suporte_legado conserva DELETE no histórico de propósito:
-- representa um privilégio residual da base anterior, neutralizado
-- pelo trigger do script 04.
-- ============================================================

\set ON_ERROR_STOP on
\encoding UTF8
\c movimentador_contas

SET timezone TO 'America/Sao_Paulo';

-- ------------------------------------------------------------
-- Higienização do schema public e do banco
-- ------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE movimentador_contas FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- ------------------------------------------------------------
-- Papéis funcionais e logins
-- ------------------------------------------------------------
CREATE ROLE role_operador_movimentacao NOLOGIN;
CREATE ROLE role_atendimento NOLOGIN;
CREATE ROLE role_auditor NOLOGIN;
CREATE ROLE role_suporte_legado NOLOGIN;
CREATE ROLE role_audit_definer NOLOGIN;

COMMENT ON ROLE role_operador_movimentacao IS
    'Inclui movimentacao e atualiza status/setor. Nao le CPF, e-mail nem saldo. Nao apaga historico.';
COMMENT ON ROLE role_atendimento IS
    'Somente views mascaradas. Nao acessa tabela base.';
COMMENT ON ROLE role_auditor IS
    'Le a trilha e as views mascaradas. Nao altera dado operacional nem a trilha.';
COMMENT ON ROLE role_suporte_legado IS
    'Privilegio residual de DELETE. A trigger cancela a exclusao do historico.';
COMMENT ON ROLE role_audit_definer IS
    'Dono das funcoes SECURITY DEFINER. Unico papel autorizado a inserir na trilha.';

CREATE ROLE usr_operador LOGIN INHERIT PASSWORD 'Operador#Trab2026';
CREATE ROLE usr_atendimento LOGIN INHERIT PASSWORD 'Atendimento#Trab2026';
CREATE ROLE usr_auditor LOGIN INHERIT PASSWORD 'Auditor#Trab2026';
CREATE ROLE usr_intruso LOGIN INHERIT PASSWORD 'Intruso#Trab2026';
CREATE ROLE usr_suporte_legado LOGIN INHERIT PASSWORD 'Legado#Trab2026';

GRANT role_operador_movimentacao TO usr_operador;
GRANT role_atendimento TO usr_atendimento;
GRANT role_auditor TO usr_auditor;
GRANT role_suporte_legado TO usr_suporte_legado;

GRANT CONNECT ON DATABASE movimentador_contas TO
    usr_operador,
    usr_atendimento,
    usr_auditor,
    usr_intruso,
    usr_suporte_legado;

ALTER ROLE usr_operador SET search_path = lgpd, contas, organizacao, identidade;
ALTER ROLE usr_atendimento SET search_path = lgpd;
ALTER ROLE usr_auditor SET search_path = lgpd, auditoria;
ALTER ROLE usr_intruso SET search_path = lgpd;
ALTER ROLE usr_suporte_legado SET search_path = contas;

-- ------------------------------------------------------------
-- Views LGPD: o dono (DBA) lê a tabela; o chamador só vê o recorte
-- security_invoker = false -> a view usa o privilegio do dono
-- security_barrier = true  -> o planejador nao empurra filtro do chamador
--                              para antes do mascaramento
-- ------------------------------------------------------------
CREATE SCHEMA lgpd;
REVOKE ALL ON SCHEMA lgpd FROM PUBLIC;

COMMENT ON SCHEMA lgpd IS
    'Superficie de consulta com minimizacao. Nao expoe CPF integral, e-mail integral nem saldo.';

CREATE FUNCTION lgpd.mascarar_cpf(p_cpf text)
RETURNS text
LANGUAGE sql
IMMUTABLE
LEAKPROOF
RETURN CASE
    WHEN p_cpf IS NULL
      OR length(regexp_replace(p_cpf, '\D', '', 'g')) <> 11
        THEN NULL
    ELSE substring(regexp_replace(p_cpf, '\D', '', 'g') FROM 1 FOR 3)
         || '.***.***-'
         || substring(regexp_replace(p_cpf, '\D', '', 'g') FROM 10 FOR 2)
END;

CREATE FUNCTION lgpd.mascarar_email(p_email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
LEAKPROOF
RETURN CASE
    WHEN p_email IS NULL OR position('@' IN p_email) = 0 THEN NULL
    ELSE left(p_email, 1) || '***' || substring(p_email FROM position('@' IN p_email))
END;

CREATE FUNCTION lgpd.mascarar_nome(p_nome text)
RETURNS text
LANGUAGE sql
IMMUTABLE
LEAKPROOF
RETURN CASE
    WHEN p_nome IS NULL THEN NULL
    WHEN position(' ' IN btrim(p_nome)) = 0 THEN btrim(p_nome)
    ELSE split_part(btrim(p_nome), ' ', 1)
         || ' '
         || left(split_part(btrim(p_nome), ' ', 2), 1)
         || '.'
END;

REVOKE ALL ON FUNCTION lgpd.mascarar_cpf(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION lgpd.mascarar_email(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION lgpd.mascarar_nome(text) FROM PUBLIC;

-- A view reescreve a consulta no chamador. Sem EXECUTE, o SELECT na view
-- falha mesmo com security_invoker = false. As funções só mascaram um
-- valor que o chamador já entrega; não leem tabela.
GRANT EXECUTE ON FUNCTION
    lgpd.mascarar_cpf(text),
    lgpd.mascarar_email(text),
    lgpd.mascarar_nome(text)
    TO role_operador_movimentacao, role_atendimento, role_auditor;

CREATE VIEW lgpd.vw_contas_mascaradas
WITH (security_barrier = true, security_invoker = false) AS
SELECT
    c.numero,
    t.descricao AS tipo,
    lgpd.mascarar_nome(c.titular_nome) AS titular,
    lgpd.mascarar_cpf(c.titular_cpf) AS cpf_mascarado,
    lgpd.mascarar_email(c.titular_email) AS email_mascarado,
    origem.nome AS setor_origem,
    atual.nome AS setor_atual,
    c.status,
    c.aberta_em
FROM contas.contas c
JOIN contas.tipos_conta t ON t.id = c.tipo_id
JOIN organizacao.setores origem ON origem.id = c.setor_origem_id
JOIN organizacao.setores atual ON atual.id = c.setor_atual_id;

COMMENT ON VIEW lgpd.vw_contas_mascaradas IS
    'Consulta operacional sem saldo e sem CPF/e-mail integrais.';

CREATE VIEW lgpd.vw_rastreabilidade
WITH (security_barrier = true, security_invoker = false) AS
SELECT
    m.protocolo,
    c.numero AS conta,
    origem.nome AS setor_origem,
    destino.nome AS setor_destino,
    col.matricula AS matricula_responsavel,
    m.motivo,
    m.ocorrido_em
FROM contas.movimentacoes m
JOIN contas.contas c ON c.id = m.conta_id
JOIN organizacao.setores origem ON origem.id = m.setor_origem_id
JOIN organizacao.setores destino ON destino.id = m.setor_destino_id
JOIN identidade.colaboradores col ON col.id = m.colaborador_id;

COMMENT ON VIEW lgpd.vw_rastreabilidade IS
    'Linha do tempo da conta sem dado pessoal do titular e sem saldo.';

-- ------------------------------------------------------------
-- Menor privilégio
-- ------------------------------------------------------------
GRANT USAGE ON SCHEMA organizacao, contas, identidade, lgpd
    TO role_operador_movimentacao;

GRANT SELECT ON organizacao.setores TO role_operador_movimentacao;
GRANT SELECT ON contas.tipos_conta TO role_operador_movimentacao;

-- Diretório interno mínimo para atribuir a movimentação. Sem CPF e sem e-mail.
GRANT SELECT (id, matricula, setor_id, ativo)
    ON identidade.colaboradores
    TO role_operador_movimentacao;

-- O operador desloca a conta, mas não enxerga titular_cpf, titular_email nem saldo.
GRANT SELECT (
    id, numero, tipo_id, setor_origem_id, setor_atual_id, status, aberta_em, atualizada_em
) ON contas.contas TO role_operador_movimentacao;

GRANT UPDATE (setor_atual_id, status, atualizada_em)
    ON contas.contas
    TO role_operador_movimentacao;

-- Histórico: ler e incluir. Sem UPDATE, sem DELETE, sem TRUNCATE.
GRANT SELECT, INSERT ON contas.movimentacoes TO role_operador_movimentacao;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA contas TO role_operador_movimentacao;

GRANT SELECT ON lgpd.vw_contas_mascaradas, lgpd.vw_rastreabilidade
    TO role_operador_movimentacao;

-- Atendimento não recebe USAGE nos schemas de tabela base.
GRANT USAGE ON SCHEMA lgpd TO role_atendimento;
GRANT SELECT ON lgpd.vw_contas_mascaradas, lgpd.vw_rastreabilidade
    TO role_atendimento;

-- Auditor lê o estado mascarado. O acesso à trilha é concedido no script 04,
-- porque o schema auditoria ainda não existe.
GRANT USAGE ON SCHEMA lgpd TO role_auditor;
GRANT SELECT ON lgpd.vw_contas_mascaradas, lgpd.vw_rastreabilidade
    TO role_auditor;

-- Privilégio residual: consegue enxergar e apagar movimentações.
-- Não recebe colunas de contas nem a view com dado de titular.
GRANT USAGE ON SCHEMA contas TO role_suporte_legado;
GRANT SELECT, DELETE ON contas.movimentacoes TO role_suporte_legado;

\echo '03securityrbac.sql concluido: PUBLIC revogado, papeis e views LGPD criados.'
