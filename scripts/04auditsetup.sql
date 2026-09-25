-- ============================================================
-- 04 — Trilha de auditoria e gatilhos
--
-- A função grava session_user (autor da sessão), não current_user.
-- Em função SECURITY DEFINER, current_user vira o dono da função
-- e esconderia a autoria.
--
-- DELETE em contas.movimentacoes é cancelado com RETURN NULL no BEFORE.
-- Assim o INSERT da trilha permanece na mesma transação.
-- Um RAISE EXCEPTION desfaria a própria evidência, porque o PostgreSQL
-- não possui transação autônoma nativa.
--
-- TRUNCATE e qualquer mudança na trilha abortam a sentença. Nesses
-- casos a evidência é o erro devolvido pelo SGBD (SQLSTATE 42501).
-- ============================================================

\set ON_ERROR_STOP on
\encoding UTF8
\c movimentador_contas

SET timezone TO 'America/Sao_Paulo';

CREATE SCHEMA auditoria;
REVOKE ALL ON SCHEMA auditoria FROM PUBLIC;

COMMENT ON SCHEMA auditoria IS
    'Trilha append-only. Leitura exclusiva do papel de auditoria.';

CREATE TABLE auditoria.trilha (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ocorrido_em      timestamptz NOT NULL DEFAULT clock_timestamp(),
    usuario_banco    text        NOT NULL,
    endereco_cliente inet,
    aplicacao        text,
    esquema          text        NOT NULL,
    tabela           text        NOT NULL,
    operacao         text        NOT NULL,
    chave_registro   text,
    dados_antigos    jsonb,
    dados_novos      jsonb,
    bloqueado        boolean     NOT NULL DEFAULT false,
    detalhe          text,
    CONSTRAINT ck_trilha_operacao CHECK (
        operacao IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
    )
);

COMMENT ON TABLE auditoria.trilha IS
    'Snapshots OLD/NEW. Contem dado pessoal quando a linha de contas e alterada; por isso somente role_auditor pode ler.';
COMMENT ON COLUMN auditoria.trilha.usuario_banco IS
    'session_user no momento do gatilho. E o autor, inclusive sob SECURITY DEFINER.';
COMMENT ON COLUMN auditoria.trilha.dados_antigos IS
    'to_jsonb(OLD). Nulo em INSERT.';
COMMENT ON COLUMN auditoria.trilha.dados_novos IS
    'to_jsonb(NEW). Nulo quando a exclusao e bloqueada.';

CREATE INDEX ix_trilha_ocorrido ON auditoria.trilha (ocorrido_em);
CREATE INDEX ix_trilha_usuario ON auditoria.trilha (usuario_banco);
CREATE INDEX ix_trilha_bloqueado ON auditoria.trilha (bloqueado) WHERE bloqueado;

CREATE FUNCTION auditoria.fn_registrar_dml()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
    v_chave text;
    v_bloqueado boolean := false;
    v_detalhe text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_new := to_jsonb(NEW);
        v_chave := NEW.id::text;
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_new := to_jsonb(NEW);
        v_chave := NEW.id::text;
    ELSIF TG_OP = 'DELETE' THEN
        v_old := to_jsonb(OLD);
        v_chave := OLD.id::text;
        IF TG_TABLE_NAME = 'movimentacoes' THEN
            v_bloqueado := true;
            v_detalhe := 'Tentativa de apagar historico de rastreabilidade. A exclusao foi cancelada e a linha original permanece.';
        END IF;
    ELSE
        RAISE EXCEPTION 'Operacao % nao suportada pela trilha.', TG_OP;
    END IF;

    INSERT INTO auditoria.trilha (
        usuario_banco,
        endereco_cliente,
        aplicacao,
        esquema,
        tabela,
        operacao,
        chave_registro,
        dados_antigos,
        dados_novos,
        bloqueado,
        detalhe
    ) VALUES (
        session_user,
        inet_client_addr(),
        nullif(current_setting('application_name', true), ''),
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        TG_OP,
        v_chave,
        v_old,
        v_new,
        v_bloqueado,
        v_detalhe
    );

    IF v_bloqueado THEN
        RAISE WARNING 'RASTREABILIDADE: exclusao do protocolo % bloqueada e registrada (usuario %)',
            OLD.protocolo, session_user;
        RETURN NULL;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE FUNCTION auditoria.fn_bloquear_truncate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    RAISE EXCEPTION 'RASTREABILIDADE: TRUNCATE em %.% e proibido (usuario %)',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, session_user
        USING ERRCODE = '42501';
END;
$$;

CREATE FUNCTION auditoria.fn_trilha_imutavel()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, auditoria
AS $$
BEGIN
    RAISE EXCEPTION 'AUDITORIA-IMUTAVEL: % na trilha e proibido (usuario %)',
        TG_OP, session_user
        USING ERRCODE = '42501';
END;
$$;

-- O dono da função precisa de CREATE no schema apenas no instante da troca.
GRANT USAGE, CREATE ON SCHEMA auditoria TO role_audit_definer;
ALTER FUNCTION auditoria.fn_registrar_dml() OWNER TO role_audit_definer;
REVOKE CREATE ON SCHEMA auditoria FROM role_audit_definer;

REVOKE ALL ON FUNCTION auditoria.fn_registrar_dml() FROM PUBLIC;
REVOKE ALL ON FUNCTION auditoria.fn_bloquear_truncate() FROM PUBLIC;
REVOKE ALL ON FUNCTION auditoria.fn_trilha_imutavel() FROM PUBLIC;

GRANT USAGE ON SCHEMA auditoria TO role_audit_definer;
GRANT INSERT ON TABLE auditoria.trilha TO role_audit_definer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA auditoria TO role_audit_definer;

GRANT USAGE ON SCHEMA auditoria TO role_auditor;
GRANT SELECT ON TABLE auditoria.trilha TO role_auditor;

ALTER TABLE auditoria.trilha ENABLE ROW LEVEL SECURITY;
ALTER TABLE auditoria.trilha FORCE ROW LEVEL SECURITY;

-- Sem política de UPDATE ou DELETE: mesmo quem receba o GRANT no futuro
-- não enxerga linha para alterar. Superusuário ignora RLS, mas não ignora
-- o trigger de imutabilidade.
CREATE POLICY trilha_insercao
    ON auditoria.trilha
    FOR INSERT
    TO role_audit_definer
    WITH CHECK (true);

CREATE POLICY trilha_leitura
    ON auditoria.trilha
    FOR SELECT
    TO PUBLIC
    USING (pg_has_role(current_user, 'role_auditor', 'MEMBER'));

CREATE TRIGGER tg_mov_bloquear_delete
    BEFORE DELETE ON contas.movimentacoes
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_registrar_dml();

CREATE TRIGGER tg_mov_auditar_escrita
    AFTER INSERT OR UPDATE ON contas.movimentacoes
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_registrar_dml();

CREATE TRIGGER tg_contas_auditar
    AFTER INSERT OR UPDATE OR DELETE ON contas.contas
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_registrar_dml();

CREATE TRIGGER tg_mov_bloquear_truncate
    BEFORE TRUNCATE ON contas.movimentacoes
    FOR EACH STATEMENT
    EXECUTE FUNCTION auditoria.fn_bloquear_truncate();

CREATE TRIGGER tg_trilha_imutavel
    BEFORE UPDATE OR DELETE ON auditoria.trilha
    FOR EACH ROW
    EXECUTE FUNCTION auditoria.fn_trilha_imutavel();

CREATE TRIGGER tg_trilha_bloquear_truncate
    BEFORE TRUNCATE ON auditoria.trilha
    FOR EACH STATEMENT
    EXECUTE FUNCTION auditoria.fn_bloquear_truncate();

\echo '04auditsetup.sql concluido: trilha, RLS e gatilhos ativos.'
