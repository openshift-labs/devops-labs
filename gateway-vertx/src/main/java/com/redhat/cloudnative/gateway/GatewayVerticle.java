package com.redhat.cloudnative.gateway;


import io.vertx.circuitbreaker.CircuitBreakerOptions;
import io.vertx.core.http.HttpMethod;
import io.vertx.core.json.Json;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.client.WebClientOptions;
import io.vertx.rxjava.circuitbreaker.CircuitBreaker;
import io.vertx.rxjava.core.AbstractVerticle;
import io.vertx.rxjava.ext.web.Router;
import io.vertx.rxjava.ext.web.RoutingContext;
import io.vertx.rxjava.ext.web.client.WebClient;
import io.vertx.rxjava.ext.web.codec.BodyCodec;
import io.vertx.rxjava.ext.web.handler.CorsHandler;
import io.vertx.rxjava.servicediscovery.ServiceDiscovery;
import io.vertx.rxjava.servicediscovery.types.HttpEndpoint;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import rx.Observable;
import rx.Single;

public class GatewayVerticle extends AbstractVerticle {
    private static final Logger LOG = LoggerFactory.getLogger(GatewayVerticle.class);

    private WebClient catalog;
    private WebClient inventory;
    private WebClient cart;
    private CircuitBreaker circuit;

    @Override
    public void start() {

        circuit = CircuitBreaker.create("inventory-circuit-breaker", vertx,
            new CircuitBreakerOptions()
                .setFallbackOnFailure(true)
                .setMaxFailures(3)
                .setResetTimeout(5000)
                .setTimeout(1000)
        );

        Router router = Router.router(vertx);
        router.route().handler(CorsHandler.create("*")
                    .allowedMethod(HttpMethod.GET)
                    .allowedMethod(HttpMethod.POST)
                    .allowedMethod(HttpMethod.DELETE)
                    .allowedHeader("Access-Control-Allow-Method")
                    .allowedHeader("Access-Control-Allow-Origin")
                    .allowedHeader("Access-Control-Allow-Credentials")
                    .allowedHeader("Content-Type"));

        router.get("/health").handler(ctx -> ctx.response().end(new JsonObject().put("status", "UP").toString()));
        router.get("/api/products").handler(this::products);
        router.get("/api/cart/:cartId").handler(this::getCart);
        router.post("/api/cart/:cartId/:itemId/:quantity").handler(this::addToCart);
        router.delete("/api/cart/:cartId/:itemId/:quantity").handler(this::deleteFromCart);

        ServiceDiscovery.create(vertx, discovery -> {
            // Catalog lookup
            Single<WebClient> catalogDiscoveryRequest = HttpEndpoint.rxGetWebClient(discovery,
                    rec -> rec.getName().equals("catalog"))
                    .onErrorReturn(t -> WebClient.create(vertx, new WebClientOptions()
                            .setDefaultHost(System.getProperty("catalog.api.host", "localhost"))
                            .setDefaultPort(Integer.getInteger("catalog.api.port", 9000))));

            // Inventory lookup
            Single<WebClient> inventoryDiscoveryRequest = HttpEndpoint.rxGetWebClient(discovery,
                    rec -> rec.getName().equals("inventory"))
                    .onErrorReturn(t -> WebClient.create(vertx, new WebClientOptions()
                            .setDefaultHost(System.getProperty("inventory.api.host", "localhost"))
                            .setDefaultPort(Integer.getInteger("inventory.api.port", 9001))));

            // Cart lookup
            Single<WebClient> cartDiscoveryRequest;
            if (Boolean.parseBoolean(System.getenv("DISABLE_CART_DISCOVERY"))) {
                LOG.info("Disable Cart discovery");
                cartDiscoveryRequest = Single.just(null);
            } else {
                cartDiscoveryRequest = HttpEndpoint.rxGetWebClient(discovery,
                        rec -> rec.getName().equals("cart"))
                        .onErrorReturn(t -> WebClient.create(vertx, new WebClientOptions()
                                .setDefaultHost(System.getProperty("cart.api.host", "localhost"))
                                .setDefaultPort(Integer.getInteger("cart.api.port", 9002))));
            }

            // Zip all 3 requests
            Single.zip(catalogDiscoveryRequest, inventoryDiscoveryRequest, cartDiscoveryRequest, (c, i, ct) -> {
                // When everything is done
                catalog = c;
                inventory = i;
                cart = ct;
                return vertx.createHttpServer()
                    .requestHandler(router::accept)
                    .listen(Integer.getInteger("http.port", 8080));
            }).subscribe();
        });
    }

    private void products(RoutingContext rc) {
        // Retrieve catalog
        catalog.get("/api/products").as(BodyCodec.jsonArray()).rxSend()
            .map(resp -> {
                if (resp.statusCode() != 200) {
                    new RuntimeException("Invalid response from the catalog: " + resp.statusCode());
                }
                return resp.body();
            })
            .flatMap(products ->
                // For each item from the catalog, invoke the inventory service
                Observable.from(products)
                    .cast(JsonObject.class)
                    .flatMapSingle(product ->
                        circuit.rxExecuteCommandWithFallback(
                            future ->
                                inventory.get("/api/inventory/" + product.getString("itemId")).as(BodyCodec.jsonObject())
                                    .rxSend()
                                    .map(resp -> {
                                        if (resp.statusCode() != 200) {
                                            LOG.warn("Inventory error for {}: status code {}",
                                                    product.getString("itemId"), resp.statusCode());
                                            return product.copy();
                                        }
                                        return product.copy().put("availability", 
                                            new JsonObject().put("quantity", resp.body().getInteger("quantity")));
                                    })
                                    .subscribe(
                                        future::complete,
                                        future::fail),
                            error -> {
                                LOG.error("Inventory error for {}: {}", product.getString("itemId"), error.getMessage());
                                return product;
                            }
                        ))
                    .toList().toSingle()
            )
            .subscribe(
                list -> rc.response().end(Json.encodePrettily(list)),
                error -> rc.response().end(new JsonObject().put("error", error.getMessage()).toString())
            );
    }

    private void getCart(RoutingContext rc) {
        String cartId = rc.request().getParam("cartId");

        if (cart == null) {
            initCartClient(rc);
        }

        circuit.executeWithFallback(
            future -> {
                cart.get("/api/cart/" + cartId).as(BodyCodec.jsonObject())
                     .send( ar -> {
                         if (ar.succeeded()) {
                             rc.response().end(ar.result().body().toString());
                             future.complete();
                         } else {
                             rc.response().end(new JsonObject().toString());
                             future.fail(ar.cause());
                         }
                     });
            }, v -> new JsonObject());
    }

    private void addToCart(RoutingContext rc) {
        String cartId = rc.request().getParam("cartId");
        String itemId = rc.request().getParam("itemId");
        String quantity = rc.request().getParam("quantity");

        if (cart == null) {
            initCartClient(rc);
        }

        circuit.executeWithFallback(
                future -> {
                    cart.post("/api/cart/" + cartId + "/" + itemId + "/" + quantity)
                            .as(BodyCodec.jsonObject())
                            .send( ar -> {
                                if (ar.succeeded()) {
                                    rc.response().end(ar.result().body().toString());
                                    future.complete();
                                } else {
                                    rc.response().end(new JsonObject().toString());
                                    future.fail(ar.cause());
                                }
                            });
                }, v -> new JsonObject());
    }

    private void deleteFromCart(RoutingContext rc) {
        String cartId = rc.request().getParam("cartId");
        String itemId = rc.request().getParam("itemId");
        String quantity = rc.request().getParam("quantity");

        if (cart == null) {
            initCartClient(rc);
        }

        circuit.executeWithFallback(
                future -> {
                    cart.delete("/api/cart/" + cartId + "/" + itemId + "/" + quantity)
                            .as(BodyCodec.jsonObject())
                            .send( ar -> {
                                if (ar.succeeded()) {
                                    rc.response().end(ar.result().body().toString());
                                    future.complete();
                                } else {
                                    rc.response().end(new JsonObject().toString());
                                    future.fail(ar.cause());
                                }
                            });
                }, v -> new JsonObject());
    }

    private void initCartClient(RoutingContext rc) {
        String cartRoute = rc.request().host().replaceAll("^gw-(.*)$", "cart-$1");
        LOG.info("Initiaizing Cart webclient at {}", cartRoute);
        cart = WebClient.create(vertx,
                new WebClientOptions()
                        .setDefaultHost(cartRoute)
                        .setDefaultPort(80));
    }
}
