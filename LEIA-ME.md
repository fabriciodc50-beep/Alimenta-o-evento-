# Lanche Coletivo da Exposição — Universo Criativo

Sistema responsivo de organização coletiva para o encontro de **15/11/2026, às 15h, na Praça São Sebastião**. Construído em HTML, CSS e JavaScript, com opção de persistência compartilhada usando Supabase.

## O que o sistema faz

- **Cadastro dos participantes:** nome, 1 alimento, 1 refrigerante de 2 litros, dinheiro para sorvete e materiais de apoio opcionais.
- **Exceção para irmãos:** um irmão pode cadastrar a garrafa de 2 litros e outro informar com quem compartilhará, sem duplicar a quantidade contabilizada.
- **Alimentos compartilhados:** as escolhas são contribuições para uma mesa coletiva, não lanches individuais.
- **100 sugestões acessíveis de comida**, 3 de bebida (água e suco apenas como alternativas para quem não toma refrigerante) e **32 tipos de materiais de apoio**.
- **Metas editáveis:** estimativa de participantes e quantidades de mesas, gelo, cooler, facas, copos, etc.
- **Conferência na chegada:** organizador marca PRESENÇA e cada ENTREGA separadamente.
- **Acompanhamento e CSV:** convidados, inscrições, promessas, quantidades recebidas, faltas e andamento.
- **Navegação móvel:** menu inferior, botão flutuante e busca.
- **Ilustração original** na capa, além dos ícones dos produtos.

## 📦 Arquivos

- `index.html`: página inicial.
- `styles.css`: design responsivo.
- `app.js`: regras e telas.
- `catalogo.js`: catálogo inicial.
- `config.js`: configuração pública da conexão.
- `schema.sql`: tabelas, validações, acessos e 135 itens para Supabase.
- `assets/`: imagens e ícones.

## 1. Testar sem publicar

Abra `index.html` no navegador ou hospede a pasta localmente. Se `config.js` estiver vazio, a página inicia em **modo demonstração** e salva as escolhas **somente no armazenamento do próprio navegador**.

Nessa condição, pessoas em celulares diferentes **não enxergam as escolhas umas das outras**. O acesso administrativo de demonstração é liberado para permitir testar os botões. **Não use o modo demonstração para organizar a exposição de verdade.**

Para abrir em servidor local, numa pasta com os arquivos:

```bash
python -m http.server 8000
```

Abra http://localhost:8000.

## 2. Ativar o banco de dados compartilhado (Supabase)

1. Abra o painel do seu projeto em https://supabase.com/dashboard.
2. Entre em **SQL Editor**, crie uma nova consulta e cole o conteúdo integral de `schema.sql`.
3. Execute. O SQL cria tabelas com prefixo `lc_`, um schema privado `lc_private`, políticas de RLS, funções de cadastro e os itens iniciais. Não altera tabelas com outros nomes.
4. No **Project Settings / API Keys** (ou integrações da Data API), copie a URL do projeto e uma chave **publishable** (`sb_publishable_...`; ou a antiga chave pública `anon`). **Nunca coloque uma chave secreta nem `service_role` no site.**
5. Edite `config.js` assim:

```javascript
window.LANCHE_CONFIG = {
  supabaseUrl: 'https://SEU-PROJETO.supabase.co',
  supabasePublishableKey: 'sb_publishable_SUA_CHAVE_PUBLICA',
  eventKey: 'exposicao-universo-criativo-2026'
};
```

6. Recarregue `index.html` e veja o indicador **Compartilhado**. Faça um cadastro de teste e abra o link em outro dispositivo para conferir que ele apareceu.

**Observação:** a Data API do projeto precisa estar ativada e permitir as tabelas/funções do schema `public`. O script já configura permissões de banco e RLS, mas projetos com Data API configurada de forma restritiva podem precisar habilitar esses recursos nas integrações do Supabase.

### Segurança do banco

- Tabelas de nomes, itens e quantidades podem ser lidas por quem tiver o link.
- Participantes não têm permissão de alterar diretamente as tabelas. Seus cadastros são criados por funções com validações no servidor.
- O cadastro gera um **código pessoal de edição** aleatório. Somente quem tem o código pode alterar ou cancelar a própria inscrição, antes da conferência.
- Esse código não é publicado na lista: o banco guarda somente um hash em schema privado.
- Apenas usuários autorizados no Supabase Auth conseguem confirmar presenças, registrar entregas e editar metas.
- Como o formulário público não exige login, **qualquer pessoa com o link pode enviar uma inscrição**. Para eventos muito grandes ou com divulgação pública, acrescente proteção anti-spam/CAPTCHA e moderação.

## 3. Criar a conta do organizador

No painel Supabase:

1. Abra **Authentication → Users** e adicione um usuário com e-mail e senha (ou um convite, conforme a configuração de seu projeto).
2. Confirme que o usuário foi criado e, se exigido, que o e-mail foi confirmado.
3. No SQL Editor, execute uma única vez o comando abaixo com o e-mail correto:

```sql
insert into public.lc_admins (user_id)
select id from auth.users
where lower(email) = lower('SEU-EMAIL@EXEMPLO.COM')
on conflict (user_id) do nothing;
```

4. No site, entre em **Gestão → Entrar como organizador** usando o e-mail e a senha desse usuário.
5. Agora você pode ajustar o catálogo, estimativas, data, local, presenças e confirmações individuais de entrega.

**Importante:** uma conta do painel do Supabase não se transforma automaticamente numa conta Auth do aplicativo. É necessário criar e autorizar o usuário acima.

## 4. Publicar no GitHub Pages

1. Crie um repositório no GitHub, por exemplo `lanche-exposicao`.
2. Coloque na **raiz do repositório** `index.html`, `styles.css`, `app.js`, `catalogo.js`, `config.js` e a pasta `assets/`.
3. No repositório, abra **Settings → Pages**.
4. Em **Build and deployment**, selecione **Deploy from a branch**, branch `main`, pasta `/ (root)`; salve.
5. Aguarde o GitHub mostrar o endereço `https://SEU-USUARIO.github.io/lanche-exposicao/`.
6. Compartilhe **somente esse link do site** com os participantes. Não compartilhe a senha de administrador ou os códigos pessoais de edição.

O GitHub Pages hospeda os arquivos visuais; as inscrições online ficam no Supabase, não no GitHub.

## 5. Uso no dia do evento

**Participante:** acessa o link, coloca seu nome, escolhe alimento e bebida, oferece itens opcionais, confirma se levará dinheiro para o sorvete e guarda o código para ajustes.

**Organizador:** abre **Gestão → Conferência** e, para cada pessoa que chegou, clica em **Confirmar chegada**. Confere os objetos/comidas realmente recebidos e clica em **Marcar entregue** para cada item. No **Painel** acompanha a diferença entre prometido e entregue; em **Exportar CSV** baixa a lista.

## 6. Editar as estimativas

Gestão → **Itens e metas** → **Editar**. Metas 0 significam item opcional, sem quantidade requerida. Para alterar expectativa total de participantes, abra **Gestão → Configurações**.

## Limitações importantes

- O site online depende de internet e Supabase funcionando.
- Sem Supabase configurado, dados de aparelhos diferentes não se sincronizam.
- Sem conta Auth autorizada, não é possível fazer conferência administrativa online.
- A sincronização online consulta novamente o banco a cada 30 segundos; o botão ↻ atualiza imediatamente.
- Não há sistema de envio de WhatsApp nem pagamento embutido.
- Em navegadores onde os dados locais são apagados, o participante precisará do código de edição guardado para recuperar sua inscrição.

---
Desenvolvido para a organização colaborativa do evento. Os nomes e as contribuições são exibidos no site por transparência entre participantes.
