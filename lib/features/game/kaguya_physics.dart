import 'dart:math' as math;

import 'package:forge2d/forge2d.dart' as box;

import 'kaguya_runtime.dart';

/// The shipped griffpatch extension uses 50 Scratch units per Box2D metre,
/// 30 simulation steps per second and 10 velocity/position iterations.
class KaguyaPhysics {
  KaguyaPhysics() {
    // Box2DWeb accepted complete drawable hulls. The two project bodies have
    // more than the eight vertices assumed by the Dart port's default setting.
    box.maxPolygonVertices = 64;
    world = box.World(box.Vector2(0, -10));
    setStage(true);
  }
  late final box.World world;
  final _bodies = <KaguyaSprite, box.Body>{};
  final _walls = <box.Body>[];
  double restitution = .2;

  void reset() {
    for (final body in _bodies.values) {
      world.destroyBody(body);
    }
    _bodies.clear();
  }

  void setStage(bool boxed) {
    for (final wall in _walls) {
      world.destroyBody(wall);
    }
    _walls.clear();
    if (!boxed) return;
    void wall(double x, double y, double halfWidth, double halfHeight) {
      final body = world.createBody(
        box.BodyDef(position: box.Vector2(x / 50, y / 50)),
      );
      final shape = box.PolygonShape()
        ..setAsBoxXY(halfWidth / 50, halfHeight / 50);
      body.createFixture(
        box.FixtureDef(shape, friction: .5, restitution: restitution),
      );
      _walls.add(body);
    }

    wall(0, -190, 490, 10);
    wall(0, 1000, 490, 10);
    wall(-250, 0, 10, 1180);
    wall(250, 0, 10, 1180);
  }

  void gravity(double x, double y) => world.gravity = box.Vector2(x, y);
  box.Body enable(KaguyaSprite sprite) {
    disable(sprite);
    final body = world.createBody(
      box.BodyDef(
        type: box.BodyType.dynamic,
        position: box.Vector2(sprite.x / 50, sprite.y / 50),
        angle: -sprite.angle,
        fixedRotation: sprite.rotationStyle != 'all around',
        bullet: true,
      ),
    );
    final c = sprite.currentCostume;
    final resolution = KaguyaRuntime.number(c['bitmapResolution'] ?? 1);
    final points =
        (c['physicsHull'] as List?) ??
        [
          [0, 0],
          [c['imageWidth'], 0],
          [c['imageWidth'], c['imageHeight']],
          [0, c['imageHeight']],
        ];
    final vertices = <box.Vector2>[
      for (final point in points)
        box.Vector2(
          (KaguyaRuntime.number(point[0]) -
                  KaguyaRuntime.number(c['rotationCenterX'])) /
              resolution *
              sprite.scaleX /
              50,
          -(KaguyaRuntime.number(point[1]) -
                  KaguyaRuntime.number(c['rotationCenterY'])) /
              resolution *
              sprite.scaleY /
              50,
        ),
    ];
    final shape = box.PolygonShape()..set(vertices);
    body.createFixture(
      box.FixtureDef(shape, density: 1, friction: .5, restitution: restitution),
    );
    _bodies[sprite] = body;
    sprite.physics = true;
    return body;
  }

  box.Body body(KaguyaSprite sprite) => _bodies[sprite] ?? enable(sprite);
  void disable(KaguyaSprite sprite) {
    final existing = _bodies.remove(sprite);
    if (existing != null) world.destroyBody(existing);
    sprite.physics = false;
  }

  void setVelocity(
    KaguyaSprite sprite,
    double x,
    double y, {
    bool change = false,
  }) {
    final b = body(sprite), velocity = box.Vector2(x * .6, y * .6);
    if (change) velocity.add(b.linearVelocity);
    b.linearVelocity = velocity;
  }

  void setAngularVelocity(KaguyaSprite sprite, double value) =>
      body(sprite).angularVelocity = -value;
  void torque(KaguyaSprite sprite, double value) =>
      body(sprite).applyTorque(-value);
  void setRestitution(KaguyaSprite sprite, double value) {
    restitution = value.clamp(0, 100) / 100;
    for (final fixture in body(sprite).fixtures) {
      fixture.restitution = restitution;
    }
  }

  void tick() {
    for (final entry in _bodies.entries.toList()) {
      final sprite = entry.key, body = entry.value;
      if (sprite.deleted) {
        disable(sprite);
        continue;
      }
      // Scratch blocks can reposition a sprite between physics steps.
      if ((body.position.x * 50 - sprite.x).abs() > .0001 ||
          (body.position.y * 50 - sprite.y).abs() > .0001 ||
          (body.angle + sprite.angle).abs() > .0001) {
        body.setTransform(
          box.Vector2(sprite.x / 50, sprite.y / 50),
          -sprite.angle,
        );
      }
    }
    world.stepDt(1 / 30);
    for (final entry in _bodies.entries) {
      entry.key.x = entry.value.position.x * 50;
      entry.key.y = entry.value.position.y * 50;
      if (entry.key.rotationStyle == 'all around') {
        entry.key.direction = 90 - entry.value.angle * 180 / math.pi;
      }
    }
  }
}
