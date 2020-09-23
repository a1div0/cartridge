describe('Auth', () => {

  before(() => {
    cy.task('tarantool', {code: `
      cleanup()

      _G.cluster = helpers.Cluster:new({
        datadir = fio.tempdir(),
        server_command = helpers.entrypoint('srv_basic'),
        use_vshard = false,
        cookie = 'test-cluster-cookie',
        replicasets = {{
          alias = 'test-replicaset',
          roles = {},
          servers = {{http_port = 8080}},
        }}
      })

      _G.cluster:start()
      return true
    `}).should('deep.eq', [true]);
  });

  after(() => {
    cy.task('tarantool', {code: `cleanup()`});
  });

  it('Open WebUI', () => {
    cy.visit('/admin/cluster/dashboard');
    cy.get('.meta-test__ProbeServerBtn').should('exist');
    cy.get('.meta-test__AuthToggle').should('not.exist');
  });

  it('Login error', () => {
    cy.get('.meta-test__LoginBtn').click();
    cy.get('.meta-test__LoginForm input[name="username"]')
      .type('error')
      .should('have.value', 'error');
    cy.get('.meta-test__LoginForm input[name="password"]')
      .type('test-cluster-cookie');
    cy.get('.meta-test__LoginFormBtn').click();
    cy.get('.meta-test__LoginForm').contains('Authentication failed');
    cy.get('.meta-test__LoginForm button[type="button"]').contains('Cancel').click();
  });

  it('Login and Enable Auth', () => {
    cy.get('.meta-test__LoginBtn').click();

    cy.get('.meta-test__LoginForm input[name="username"]')
      .type('admin')
      .should('have.value', 'admin');
    cy.get('.meta-test__LoginForm input[name="password"]')
      .type('test-cluster-cookie');
    cy.get('.meta-test__LoginFormBtn').click();

    cy.get('a[href="/admin/cluster/users"]').click();
    cy.get('.meta-test__AuthToggle input').should('not.be.checked')
    cy.get('.meta-test__AuthToggle').click();
    cy.get('.meta-test__ConfirmModal').contains('Enable').click();
  });

  it('Logout', () => {
    cy.get('.meta-test__LogoutBtn').click();
    cy.get('.meta-test__LogoutDropdown *').contains('Log out').click();
  });
  
  it('Login and Disable auth', () => {
    // cy.get('a[href="/admin/cluster/dashboard"]').click()
    cy.get('.meta-test__LoginFormSplash').should('exist');

    cy.get('input[name="username"]').type('admin');
    cy.get('input[name="password"]').type('test-cluster-cookie');
    cy.get('.meta-test__LoginFormBtn').click();

    cy.get('a[href="/admin/cluster/users"]').click();
    cy.get('.meta-test__AuthToggle input').should('be.checked');
    cy.get('.meta-test__AuthToggle').click();
    cy.get('.meta-test__ConfirmModal').contains('Disable').click();
    cy.get('.meta-test__AuthToggle input').should('not.be.checked');
  });

  it('Disabled users page usecase ', () => {
    cy.task('tarantool', {code: `
      _G.cluster.main_server:stop()
      _G.cluster.main_server.command = helpers.entrypoint('srv_woauth')
      _G.cluster.main_server:start()
      return true
    `}).should('deep.eq', [true]);
    cy.get('a[href="/admin/cluster/dashboard"]').click();
    cy.reload();

    cy.get('.meta-test__AuthToggle').should('exist');
    cy.get('a[href="/admin/cluster/users"]').should('not.exist');
  });
});
