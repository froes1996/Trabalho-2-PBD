import os
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, flash
import psycopg
from psycopg.rows import dict_row

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY", "chave-secreta-terminal-2026")

DB_DSN = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres:31994@localhost:5432/terminal_logistico"
)


def get_db_connection():
    return psycopg.connect(
        host="localhost",
        port=5432,
        dbname="terminal_logistico",
        user="postgres",
        password="31994",
        row_factory=dict_row,
    )


def extrair_erro_pg(err: psycopg.Error) -> str:
    if getattr(err, "diag", None) and err.diag.message_primary:
        return err.diag.message_primary
    return str(err)


@app.route("/")
def index():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM fn_indicadores_ocupacao_patio();")
            indicadores_patio = cur.fetchall()

            cur.execute("""
                SELECT c.*, b.codigo_bloco
                  FROM containers c
                  LEFT JOIN blocos_patio b ON b.id = c.bloco_id
                 ORDER BY c.id DESC;
            """)
            containers = cur.fetchall()

            cur.execute("""
                SELECT o.*,
                       v.placa_cavalo,
                       v.placa_carreta,
                       v.pbtc_maximo_kg,
                       c.numero_iso,
                       c.tipo AS tipo_container,
                       fn_calcular_peso_liquido(o.id) AS peso_liquido_calculado
                  FROM ordens_pesagem o
                  JOIN veiculos v ON v.id = o.veiculo_id
                  JOIN containers c ON c.id = o.container_id
                 ORDER BY o.id DESC;
            """)
            ordens = cur.fetchall()
            cur.execute("""
                SELECT v.*, t.razao_social
                  FROM veiculos v
                  JOIN transportadoras t ON t.id = v.transportadora_id
                 ORDER BY v.placa_cavalo;
            """)
            veiculos = cur.fetchall()

            cur.execute("SELECT * FROM blocos_patio ORDER BY codigo_bloco;")
            blocos = cur.fetchall()

    return render_template(
        "index.html",
        indicadores_patio=indicadores_patio,
        containers=containers,
        ordens=ordens,
        veiculos=veiculos,
        blocos=blocos,
    )


@app.route("/pesagens/entrada", methods=["POST"])
def registrar_entrada_balanca():
    veiculo_id = request.form.get("veiculo_id")
    container_id = request.form.get("container_id")
    tipo_operacao = request.form.get("tipo_operacao")
    peso_entrada_kg = request.form.get("peso_entrada_kg")
    protocolo = f"BAL-{datetime.now().strftime('%Y%m%d%H%M%S')}"

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO ordens_pesagem
                        (protocolo, veiculo_id, container_id, tipo_operacao, peso_entrada_kg)
                    VALUES (%s, %s, %s, %s, %s);
                    """,
                    (protocolo, veiculo_id, container_id, tipo_operacao, peso_entrada_kg),
                )
            conn.commit()
        flash(f"Entrada registrada com sucesso! Protocolo: {protocolo}.", "success")
    except psycopg.Error as e:
        flash(extrair_erro_pg(e), "danger")

    return redirect(url_for("index"))


@app.route("/pesagens/<int:ordem_id>/finalizar", methods=["POST"])
def finalizar_pesagem(ordem_id):
    peso_saida_kg = request.form.get("peso_saida_kg")

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "CALL sp_finalizar_pesagem_saida(%s, %s);",
                    (ordem_id, peso_saida_kg),
                )
            conn.commit()
        flash("Pesagem de saída concluída, peso líquido apurado e status atualizado.", "success")
    except psycopg.Error as e:
        flash(extrair_erro_pg(e), "danger")

    return redirect(url_for("index"))


@app.route("/patio/alocar", methods=["POST"])
def alocar_container():
    container_id = request.form.get("container_id")
    bloco_id = request.form.get("bloco_id")

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "CALL sp_alocar_container_patio(%s, %s);",
                    (container_id, bloco_id),
                )
            conn.commit()
        flash("Contêiner alocado/remanejado no pátio com sucesso!", "success")
    except psycopg.Error as e:
        flash(extrair_erro_pg(e), "danger")

    return redirect(url_for("index"))


@app.route("/containers/novo", methods=["POST"])
def cadastrar_container():
    numero_iso = request.form.get("numero_iso", "").strip().upper()
    tipo = request.form.get("tipo")
    tara_kg = request.form.get("tara_kg")

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO containers (numero_iso, tipo, tara_kg, status)
                    VALUES (%s, %s, %s, 'AGUARDANDO_GATE');
                    """,
                    (numero_iso, tipo, tara_kg),
                )
            conn.commit()
        flash(f"Contêiner {numero_iso} pré-cadastrado no Gate.", "success")
    except psycopg.Error as e:
        flash(extrair_erro_pg(e), "danger")

    return redirect(url_for("index"))


@app.route("/containers/<int:container_id>/inspecao", methods=["POST"])
def alternar_inspecao(container_id):
    novo_status = request.form.get("novo_status")

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE containers SET status = %s WHERE id = %s;",
                    (novo_status, container_id),
                )
            conn.commit()
        flash(f"Status do contêiner alterado para {novo_status} (registrado na auditoria).", "info")
    except psycopg.Error as e:
        flash(extrair_erro_pg(e), "danger")

    return redirect(url_for("index"))


@app.route("/auditoria")
def auditoria():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT a.*,
                       c.numero_iso,
                       c.tipo AS tipo_container,
                       ba.codigo_bloco AS bloco_anterior,
                       bn.codigo_bloco AS bloco_novo
                  FROM auditoria_containers a
                  JOIN containers c ON c.id = a.container_id
                  LEFT JOIN blocos_patio ba ON ba.id = a.bloco_anterior_id
                  LEFT JOIN blocos_patio bn ON bn.id = a.bloco_novo_id
                 ORDER BY a.registrado_em DESC, a.id DESC;
            """)
            registros = cur.fetchall()

    return render_template("auditoria.html", registros=registros)


if __name__ == "__main__":
    app.run(debug=True)