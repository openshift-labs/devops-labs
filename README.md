# DevOps Workshop Labs [![Build Status](https://travis-ci.org/openshift-labs/devops-labs.svg?branch=ocp-3.7)](https://travis-ci.org/openshift-labs/devops-labs)

CoolStore is an online store web application built using Spring Boot, WildFly Swarm, Eclipse Vert.x, 
Node.js and AngularJS adopting the microservices architecture.

* **Web**: A Node.js/Angular front-end
* **API Gateway**: vert.x service aggregates API calls to back-end services and provides a condenses REST API for front-end
* **Catalog**: Spring Boot service exposing REST API for the product catalog and product information
* **Inventory**: WildFly Swarm service exposing REST API for product's inventory status
* **Cart**: Spring Boot service exposing REST API for shopping cart

```
                              +-------------+
                              |             |
                              |     Web     |
                              |             |
                              |   Node.js   |
                              |  AngularJS  |
                              +------+------+
                                     |
                                     v
                              +------+------+
                              |             |
                              | API Gateway |
                              |             |
                              |   Vert.x    |
                              |             |
                              +------+------+
                                     |
                 +---------+---------+-------------------+
                 v                   v                   v
          +------+------+     +------+------+     +------+------+
          |             |     |             |     |             |
          |   Catalog   |     |  Inventory  |     |     Cart    |
          |             |     |             |     |             |
          | Spring Boot |     |WildFly Swarm|     | Spring Boot |
          |             |     |             |     |             |
          +-------------+     +-------------+     +-------------+
```