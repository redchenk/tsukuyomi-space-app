import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'kaguya_physics.dart';

/// Native interpreter for the actual Scratch project embedded in Kaguya Run.
/// Runs at the original 30 Hz, with broadcast hats, clone-local variables,
/// cooperative loops, procedure calls and the original costume/sound assets.
class KaguyaRuntime extends ChangeNotifier {
  KaguyaRuntime(Map<String, dynamic> project, {math.Random? random})
    : random = random ?? math.Random() {
    for (final raw in project['targets'] as List) {
      sprites.add(KaguyaSprite(Map<String, dynamic>.from(raw)));
    }
  }
  static const supportedOpcodes = <String>{
    'control_create_clone_of',
    'control_delete_this_clone',
    'control_forever',
    'control_if',
    'control_if_else',
    'control_repeat',
    'control_repeat_until',
    'control_start_as_clone',
    'control_stop',
    'control_wait',
    'control_wait_until',
    'cubesterKeySimulation_pressKey',
    'data_addtolist',
    'data_changevariableby',
    'data_itemoflist',
    'data_lengthoflist',
    'data_setvariableto',
    'event_broadcast',
    'event_broadcastandwait',
    'event_whenbroadcastreceived',
    'event_whenflagclicked',
    'event_whenthisspriteclicked',
    'griffpatch_applyAngForce',
    'griffpatch_changeVelocity',
    'griffpatch_disablePhysics',
    'griffpatch_doTick',
    'griffpatch_setAngVelocity',
    'griffpatch_setGravity',
    'griffpatch_setPhysics',
    'griffpatch_setRestitutionValue',
    'griffpatch_setStage',
    'griffpatch_setVelocity',
    'jeremygamerTweening_tweenXY',
    'lmsclonesplus_isClone',
    'looks_changeeffectby',
    'looks_changesizeby',
    'looks_cleargraphiceffects',
    'looks_costumenumbername',
    'looks_goforwardbackwardlayers',
    'looks_gotofrontback',
    'looks_hide',
    'looks_nextcostume',
    'looks_seteffectto',
    'looks_setsizeto',
    'looks_show',
    'looks_size',
    'looks_switchcostumeto',
    'motion_changexby',
    'motion_changeyby',
    'motion_goto',
    'motion_gotoxy',
    'motion_movesteps',
    'motion_pointindirection',
    'motion_setrotationstyle',
    'motion_setx',
    'motion_sety',
    'motion_xposition',
    'motion_yposition',
    'nkmoremotion_distanceto',
    'nkmoremotion_steptowards',
    'operator_add',
    'operator_and',
    'operator_contains',
    'operator_divide',
    'operator_equals',
    'operator_gt',
    'operator_join',
    'operator_length',
    'operator_letter_of',
    'operator_lt',
    'operator_mathop',
    'operator_multiply',
    'operator_not',
    'operator_or',
    'operator_random',
    'operator_round',
    'operator_subtract',
    'procedures_call',
    'procedures_definition',
    'procedures_prototype',
    'sensing_keypressed',
    'sensing_mousedown',
    'sensing_of',
    'sensing_resettimer',
    'sensing_timer',
    'sensing_touchingobject',
    'sound_changevolumeby',
    'sound_play',
    'sound_playuntildone',
    'sound_setvolumeto',
    'sound_stopallsounds',
    'stretch_setStretch',
    'stretch_setStretchX',
    'stretch_setStretchY',
    'text_animateText',
    'text_setColor',
    'text_setFont',
    'text_setOutlineColor',
    'text_setOutlineWidth',
    'text_setShakeIntensity',
    'text_setWidth',
    'text_startAnimate',
  };
  Set<String> get unsupportedProjectOpcodes => {
    for (final sprite in sprites)
      for (final block in sprite.blocks.values)
        if (block is Map &&
            !supportedOpcodes.contains(block['opcode']) &&
            !('${block['opcode']}'.endsWith('_menu') ||
                '${block['opcode']}'.contains('_menu_') ||
                [
                  'looks_costume',
                  'sensing_keyoptions',
                  'sensing_touchingobjectmenu',
                  'text_menu_twAnimate',
                  'motion_goto_menu',
                ].contains(block['opcode'])))
          '${block['opcode']}',
  };
  final math.Random random;
  final physics = KaguyaPhysics();
  final sprites = <KaguyaSprite>[];
  void setMasks(Uint8List masks) {
    for (final sprite in sprites) {
      sprite.masks = masks;
    }
  }

  final _threads = <_Thread>[];
  final keys = <String>{}, _simulated = <String, double>{};
  final unknownOpcodes = <String>{};
  final Set<String> executedOpcodes = {};
  bool running = false, paused = false, mouseDown = false, muted = false;
  double mouseX = 0,
      mouseY = 0,
      time = 0,
      _timerStart = 0,
      _accumulator = 0,
      gravityX = 0,
      gravityY = -10;
  int _nextClone = 0, _frame = 0, _cycleBase = 0, _cycleAt = -1;
  bool boxed = true;
  void Function(
    KaguyaSprite sprite,
    Map<String, dynamic> sound,
    bool untilDone,
  )?
  onSound;
  VoidCallback? onStopSounds;
  KaguyaSprite get stage => sprites.firstWhere((s) => s.isStage);
  int get score =>
      number(variableByName('分数')).floor().clamp(0, 9007199254740991);
  double get mood => number(variableByName('心情值'));
  int get cloneCount => sprites.where((s) => s.isClone).length;
  int get activeThreads => _threads.where((t) => !t.dead).length;
  @visibleForTesting
  List<Map<String, dynamic>> get executionState => [
    for (final t in _threads.where((t) => !t.dead))
      {
        'sprite': t.sprite.name,
        'hat': t.hat,
        'pc': t.pc,
        'opcode': (t.sprite.blocks[t.pc] as Map?)?['opcode'],
        'until': t.until,
        'stack': [for (final f in t.stack) '${f.kind}:${f.count}:${f.body}'],
        'warp': t.warpDepth,
      },
  ];
  dynamic variableByName(String name) {
    for (final value in stage.variables.values) {
      if (value[0] == name) return value[1];
    }
    return 0;
  }

  void setVariableByName(String name, dynamic value) {
    for (final variable in stage.variables.values) {
      if (variable[0] == name) {
        variable[1] = value;
        return;
      }
    }
  }

  void greenFlag({bool preserveCycle = false}) {
    onStopSounds?.call();
    _threads.clear();
    physics.reset();
    sprites.removeWhere((s) => s.isClone);
    running = true;
    paused = false;
    mouseDown = false;
    keys.clear();
    _simulated.clear();
    if (!preserveCycle) {
      _cycleBase = 0;
      _cycleAt = -1;
      time = 0;
      _frame = 0;
      _timerStart = 0;
    }
    for (final s in sprites) {
      s.effects.clear();
      s.physics = false;
    }
    _hats('event_whenflagclicked');
    notifyListeners();
  }

  void restart() => greenFlag();
  void startGame() {
    final start = _find('开始游戏');
    if (start != null && start.visible) {
      _hats('event_whenthisspriteclicked', target: start);
    }
  }

  void togglePause() {
    paused = !paused;
    notifyListeners();
  }

  void key(String key, bool down) {
    key = normalizeKey(key);
    if (down) {
      keys.add(key);
    } else {
      keys.remove(key);
    }
  }

  static String normalizeKey(String value) => switch (value.toLowerCase()) {
    'arrowup' => 'up arrow',
    'arrowdown' => 'down arrow',
    'arrowleft' => 'left arrow',
    'arrowright' => 'right arrow',
    ' ' => 'space',
    final other => other,
  };
  void tapKey(String value, {double seconds = .12}) {
    _simulated[normalizeKey(value)] = time + seconds;
  }

  void click(double x, double y, {bool down = true}) {
    mouseX = x;
    mouseY = y;
    mouseDown = down;
    if (!down) return;
    final visible =
        sprites.where((s) => !s.isStage && s.visible && !s.deleted).toList()
          ..sort((a, b) => b.layer.compareTo(a.layer));
    for (final s in visible) {
      if (s.containsPoint(Offset(x, y))) {
        _hats('event_whenthisspriteclicked', target: s);
        break;
      }
    }
  }

  void broadcast(String name) => _broadcast(name);
  List<_Thread> _broadcast(String name) =>
      _hats('event_whenbroadcastreceived', broadcast: name);
  List<_Thread> _hats(
    String opcode, {
    KaguyaSprite? target,
    String? broadcast,
  }) {
    final result = <_Thread>[];
    for (final s in List<KaguyaSprite>.of(
      target == null ? sprites : [target],
    )) {
      if (s.deleted) continue;
      for (final entry in s.blocks.entries) {
        final b = entry.value;
        if (b is! Map || b['opcode'] != opcode) continue;
        if (broadcast != null && _field(b, 'BROADCAST_OPTION') != broadcast) {
          continue;
        }
        // Scratch restarts an already-running identical broadcast hat.
        for (final t in _threads) {
          if (t.sprite == s && t.hat == entry.key) t.dead = true;
        }
        final thread = _Thread(s, entry.key, b['next'] as String?);
        _threads.add(thread);
        result.add(thread);
      }
    }
    return result;
  }

  void advance(double seconds) {
    if (!running || paused) return;
    _accumulator += seconds.clamp(0.0, .25);
    while (_accumulator >= 1 / 30) {
      _accumulator -= 1 / 30;
      _tick();
    }
    notifyListeners();
  }

  void _tick() {
    time += 1 / 30;
    _frame++;
    _simulated.removeWhere((_, until) => until < time);
    final current = List<_Thread>.of(_threads);
    for (final thread in current) {
      if (!running) break;
      if (thread.dead || thread.sprite.deleted) continue;
      if (thread.until > time) continue;
      if (thread.waiting != null && thread.waiting!.any((t) => !t.dead)) {
        continue;
      }
      thread.waiting = null;
      if (thread.tween != null) {
        final tween = thread.tween!;
        final f = ((time - tween.start) / tween.seconds).clamp(0.0, 1.0);
        final eased = tween.mode == 'sine'
            ? switch (tween.direction) {
                'in' => 1 - math.cos(math.pi * f / 2),
                'out' => math.sin(math.pi * f / 2),
                'in out' => -(math.cos(math.pi * f) - 1) / 2,
                _ => 0.0,
              }
            : f;
        thread.sprite.x = tween.x + (tween.toX - tween.x) * eased;
        thread.sprite.y = tween.y + (tween.toY - tween.y) * eased;
        if (f < 1) continue;
        thread.sprite.x = tween.toX;
        thread.sprite.y = tween.toY;
        thread.tween = null;
      }
      for (
        var operations = 0;
        operations < 10000 && !thread.dead;
        operations++
      ) {
        if (thread.pc == null) {
          if (!_resume(thread)) break;
          if (thread.yielded) {
            thread.yielded = false;
            break;
          }
          continue;
        }
        final block = thread.sprite.blocks[thread.pc];
        if (block is! Map) {
          thread.pc = null;
          continue;
        }
        if (_execute(thread, block)) break;
      }
    }
    _threads.removeWhere((t) => t.dead || t.sprite.deleted);
    sprites.removeWhere((s) => s.deleted);
    _postgameCycle();
  }

  bool _resume(_Thread t) {
    if (t.stack.isEmpty) {
      t.dead = true;
      return false;
    }
    final frame = t.stack.last;
    if (frame.kind == 'procedure') {
      t.warpDepth--;
      t.stack.removeLast();
      t.pc = frame.next;
      return true;
    }
    if (frame.kind == 'resume') {
      t.stack.removeLast();
      t.pc = frame.next;
      return true;
    }
    var repeat = frame.kind == 'forever';
    if (frame.kind == 'repeat') {
      frame.count--;
      repeat = frame.count > 0;
    }
    if (frame.kind == 'until') {
      repeat = !truth(_input(t.sprite, frame.block!, 'CONDITION'));
    }
    if (repeat) {
      t.pc = frame.body;
      t.yielded = t.warpDepth == 0;
    } else {
      t.stack.removeLast();
      t.pc = frame.next;
    }
    return true;
  }

  void _branch(
    _Thread t,
    String? body,
    String? next, {
    String kind = 'resume',
    int count = 0,
    Map? block,
  }) {
    t.stack.add(_Frame(kind, body, next, count, block));
    t.pc = body;
  }

  bool _execute(_Thread t, Map b) {
    final s = t.sprite, op = '${b['opcode']}';
    executedOpcodes.add(op);
    final next = b['next'] as String?;
    t.pc = next;
    dynamic input(String name) => _input(s, b, name);
    double n(String name) => number(input(name));
    String text(String name) => '${input(name)}';
    switch (op) {
      case 'control_wait':
        t.until = time + math.max(0, n('DURATION'));
        return true;
      case 'control_wait_until':
        if (!truth(input('CONDITION'))) {
          t.pc = _blockId(s, b);
          return true;
        }
      case 'control_repeat':
        final count = n('TIMES').round();
        if (count > 0) {
          _branch(t, _sub(b, 'SUBSTACK'), next, kind: 'repeat', count: count);
        }
      case 'control_forever':
        _branch(t, _sub(b, 'SUBSTACK'), null, kind: 'forever');
      case 'control_repeat_until':
        if (!truth(input('CONDITION'))) {
          _branch(t, _sub(b, 'SUBSTACK'), next, kind: 'until', block: b);
        }
      case 'control_if':
        if (truth(input('CONDITION'))) _branch(t, _sub(b, 'SUBSTACK'), next);
      case 'control_if_else':
        _branch(
          t,
          _sub(b, truth(input('CONDITION')) ? 'SUBSTACK' : 'SUBSTACK2'),
          next,
        );
      case 'control_stop':
        final what = _field(b, 'STOP_OPTION');
        if (what == 'all') {
          _threads.clear();
          running = false;
          onStopSounds?.call();
          return true;
        }
        if (what == 'other scripts in sprite') {
          for (final v in _threads) {
            if (v.sprite == s && v != t) v.dead = true;
          }
        } else {
          t.dead = true;
          return true;
        }
      case 'event_broadcast':
        broadcast(text('BROADCAST_INPUT'));
      case 'event_broadcastandwait':
        t.waiting = _broadcast(text('BROADCAST_INPUT'));
        return true;
      case 'procedures_call':
        final code = (b['mutation'] as Map?)?['proccode'];
        for (final d in s.blocks.values) {
          if (d is! Map || d['opcode'] != 'procedures_definition') continue;
          final prototype = s.blocks[_sub(d, 'custom_block')];
          if (prototype is Map &&
              (prototype['mutation'] as Map?)?['proccode'] == code) {
            t.warpDepth++;
            _branch(t, d['next'] as String?, next, kind: 'procedure');
            break;
          }
        }
      case 'data_setvariableto':
        _setVariable(s, _field(b, 'VARIABLE', id: true), input('VALUE'));
      case 'data_changevariableby':
        final id = _field(b, 'VARIABLE', id: true);
        _setVariable(s, id, number(_variable(s, id)) + n('VALUE'));
      case 'data_addtolist':
        _list(s, _field(b, 'LIST', id: true)).add(input('ITEM'));
      case 'motion_gotoxy':
        s.x = n('X');
        s.y = n('Y');
      case 'motion_changexby':
        s.x += n('DX');
      case 'motion_changeyby':
        s.y += n('DY');
      case 'motion_setx':
        s.x = n('X');
      case 'motion_sety':
        s.y = n('Y');
      case 'motion_pointindirection':
        s.direction = n('DIRECTION');
      case 'motion_movesteps':
        s.x += math.sin(s.direction * math.pi / 180) * n('STEPS');
        s.y += math.cos(s.direction * math.pi / 180) * n('STEPS');
      case 'motion_setrotationstyle':
        s.rotationStyle = _field(b, 'STYLE');
      case 'motion_goto':
        final name = text('TO');
        if (name == '_mouse_') {
          s.x = mouseX;
          s.y = mouseY;
        } else if (name == '_random_') {
          s.x = random.nextDouble() * 480 - 240;
          s.y = random.nextDouble() * 360 - 180;
        } else {
          final target = _find(name);
          if (target != null) {
            s.x = target.x;
            s.y = target.y;
          }
        }
      case 'looks_show':
        s.visible = true;
      case 'looks_hide':
        s.visible = false;
      case 'looks_setsizeto':
        s.size = n('SIZE').clamp(.001, 1000000);
      case 'looks_changesizeby':
        s.size = (s.size + n('CHANGE')).clamp(.001, 1000000);
      case 'looks_switchcostumeto':
        s.switchCostume(input('COSTUME'));
      case 'looks_nextcostume':
        s.costume = (s.costume + 1) % s.costumes.length;
      case 'looks_seteffectto':
        s.effects[_field(b, 'EFFECT').toLowerCase()] = n('VALUE');
      case 'looks_changeeffectby':
        final effect = _field(b, 'EFFECT').toLowerCase();
        s.effects[effect] = (s.effects[effect] ?? 0) + n('CHANGE');
      case 'looks_cleargraphiceffects':
        s.effects.clear();
      case 'looks_gotofrontback':
        final layers = sprites.map((s) => s.layer).toList();
        s.layer = _field(b, 'FRONT_BACK') == 'front'
            ? layers.reduce(math.max) + 1
            : layers.reduce(math.min) - 1;
      case 'looks_goforwardbackwardlayers':
        s.layer +=
            (_field(b, 'FORWARD_BACKWARD') == 'forward' ? 1 : -1) *
            n('NUM').toInt();
      case 'sound_setvolumeto':
        s.volume = n('VOLUME').clamp(0, 100);
      case 'sound_changevolumeby':
        s.volume = (s.volume + n('VOLUME')).clamp(0, 100);
      case 'sound_stopallsounds':
        onStopSounds?.call();
      case 'sound_play':
      case 'sound_playuntildone':
        final name = text('SOUND_MENU');
        Map<String, dynamic>? sound;
        for (final candidate in s.sounds) {
          if ('${candidate['name']}' == name) {
            sound = candidate;
            break;
          }
        }
        if (sound == null && s.sounds.isNotEmpty) {
          sound = s.sounds[(number(name).toInt() - 1) % s.sounds.length];
        }
        if (sound != null) {
          onSound?.call(s, sound, op == 'sound_playuntildone');
          if (op == 'sound_playuntildone') {
            t.until =
                time + number(sound['sampleCount']) / number(sound['rate']);
            return true;
          }
        }
      case 'control_create_clone_of':
        final name = text('CLONE_OPTION'),
            original = name == '_myself_' ? s : _find(name);
        if (original != null && cloneCount < 300) {
          final clone = original.clone(++_nextClone);
          sprites.add(clone);
          _hats('control_start_as_clone', target: clone);
        }
      case 'control_delete_this_clone':
        if (s.isClone) {
          s.deleted = true;
          t.dead = true;
          return true;
        }
      case 'stretch_setStretch':
        s.stretchX = n('X');
        s.stretchY = n('Y');
      case 'stretch_setStretchX':
        s.stretchX = n('X');
      case 'stretch_setStretchY':
        s.stretchY = n('Y');
      case 'cubesterKeySimulation_pressKey':
        tapKey(text('KEY'), seconds: n('SECONDS'));
        if (text('AND_WAIT') == 'true') {
          t.until = time + n('SECONDS');
          return true;
        }
      case 'sensing_resettimer':
        _timerStart = time;
      case 'jeremygamerTweening_tweenXY':
        t.tween = _Tween(
          time,
          math.max(.001, n('SEC')),
          s.x,
          s.y,
          n('X'),
          n('Y'),
          text('MODE').toLowerCase(),
          text('DIRECTION').toLowerCase(),
        );
        return true;
      case 'nkmoremotion_steptowards':
        final dx = n('X') - s.x,
            dy = n('Y') - s.y,
            distance = math.sqrt(dx * dx + dy * dy);
        if (distance > 0) {
          s.x += dx / distance * n('STEPS');
          s.y += dy / distance * n('STEPS');
        }
      case 'griffpatch_setStage':
        boxed = _field(b, 'stageType') == 'boxed';
        physics.setStage(boxed);
      case 'griffpatch_setGravity':
        gravityX = n('gx');
        gravityY = n('gy');
        physics.gravity(gravityX, gravityY);
      case 'griffpatch_setPhysics':
        physics.enable(s);
      case 'griffpatch_disablePhysics':
        physics.disable(s);
      case 'griffpatch_setVelocity':
        physics.setVelocity(s, n('sx'), n('sy'));
      case 'griffpatch_changeVelocity':
        physics.setVelocity(s, n('sx'), n('sy'), change: true);
      case 'griffpatch_setAngVelocity':
        physics.setAngularVelocity(s, n('force'));
      case 'griffpatch_applyAngForce':
        physics.torque(s, n('force'));
      case 'griffpatch_setRestitutionValue':
        physics.setRestitution(s, n('restitution'));
      case 'griffpatch_doTick':
        physics.tick();
      case 'text_animateText':
        s.text = text('TEXT');
        s.textStarted = time;
        s.textAnimation = _field(b, 'ANIMATE');
        // The shipped text extension reveals the first code unit immediately,
        // then one every 1/15 s. animateText blocks until that animation ends.
        if (s.textAnimation == 'type') {
          t.until = time + math.max(1, s.text.length - 1) / 15;
          return true;
        }
      case 'text_setFont':
        s.font = _field(b, 'FONT');
      case 'text_setColor':
        s.textColor = text('COLOR');
      case 'text_setWidth':
        s.textWidth = n('WIDTH');
      case 'text_setOutlineWidth':
        s.outlineWidth = n('WIDTH');
      case 'text_setOutlineColor':
        s.outlineColor = text('COLOR');
      case 'text_setShakeIntensity':
        s.shake = n('NUM');
      case 'text_startAnimate':
        s.textAnimation = text('ANIMATE');
        s.textStarted = time;
      default:
        unknownOpcodes.add(op);
    }
    return false;
  }

  dynamic _input(KaguyaSprite s, Map b, String name) {
    final source = (b['inputs'] as Map?)?[name];
    return source is List && source.length > 1 ? _value(s, source[1]) : 0;
  }

  dynamic _value(KaguyaSprite s, dynamic source) {
    if (source is List) {
      if (source[0] == 12) {
        return _variable(s, '${source.length > 2 ? source[2] : source[1]}');
      }
      if (source[0] == 13) {
        return _list(s, '${source.length > 2 ? source[2] : source[1]}');
      }
      return source.length > 1 ? source[1] : 0;
    }
    final b = s.blocks[source];
    if (b is! Map) return source ?? 0;
    final op = '${b['opcode']}';
    executedOpcodes.add(op);
    dynamic input(String name) => _input(s, b, name);
    double n(String name) => number(input(name));
    String text(String name) => '${input(name)}';
    switch (op) {
      case 'operator_add':
        return n('NUM1') + n('NUM2');
      case 'operator_subtract':
        return n('NUM1') - n('NUM2');
      case 'operator_multiply':
        return n('NUM1') * n('NUM2');
      case 'operator_divide':
        return n('NUM1') / n('NUM2');
      case 'operator_random':
        final a = n('FROM'), b = n('TO');
        final low = math.min(a, b), high = math.max(a, b);
        return a == a.roundToDouble() && b == b.roundToDouble()
            ? low + random.nextInt((high - low + 1).toInt())
            : low + random.nextDouble() * (high - low);
      case 'operator_gt':
        return compare(input('OPERAND1'), input('OPERAND2')) > 0;
      case 'operator_lt':
        return compare(input('OPERAND1'), input('OPERAND2')) < 0;
      case 'operator_equals':
        return compare(input('OPERAND1'), input('OPERAND2')) == 0;
      case 'operator_and':
        return truth(input('OPERAND1')) && truth(input('OPERAND2'));
      case 'operator_or':
        return truth(input('OPERAND1')) || truth(input('OPERAND2'));
      case 'operator_not':
        return !truth(input('OPERAND'));
      case 'operator_join':
        return '${input('STRING1')}${input('STRING2')}';
      case 'operator_contains':
        return text('STRING1')
            .toLowerCase()
            .contains(text('STRING2').toLowerCase());
      case 'operator_length':
        return text('STRING').length;
      case 'operator_letter_of':
        final value = text('STRING'), index = n('LETTER').toInt() - 1;
        return index < 0 || index >= value.length ? '' : value[index];
      case 'operator_round':
        return n('NUM').round();
      case 'operator_mathop':
        final value = n('NUM');
        return switch (_field(b, 'OPERATOR')) {
          'abs' => value.abs(),
          'floor' => value.floor(),
          'ceiling' => value.ceil(),
          'sqrt' => math.sqrt(value),
          'sin' => math.sin(value * math.pi / 180),
          'cos' => math.cos(value * math.pi / 180),
          'tan' => math.tan(value * math.pi / 180),
          'asin' => math.asin(value) * 180 / math.pi,
          'acos' => math.acos(value) * 180 / math.pi,
          'atan' => math.atan(value) * 180 / math.pi,
          'ln' => math.log(value),
          'log' => math.log(value) / math.ln10,
          'e ^' => math.exp(value),
          '10 ^' => math.pow(10, value),
          _ => 0,
        };
      case 'motion_xposition':
        return s.x;
      case 'motion_yposition':
        return s.y;
      case 'looks_size':
        return s.size;
      case 'looks_costumenumbername':
        return _field(b, 'NUMBER_NAME') == 'name'
            ? s.currentCostume['name']
            : s.costume + 1;
      case 'lmsclonesplus_isClone':
        return s.isClone;
      case 'sensing_keypressed':
        final name = normalizeKey(text('KEY_OPTION'));
        return name == 'any'
            ? keys.isNotEmpty || _simulated.isNotEmpty
            : keys.contains(name) || _simulated.containsKey(name);
      case 'sensing_mousedown':
        return mouseDown;
      case 'sensing_timer':
        return time - _timerStart;
      case 'sensing_touchingobject':
        final name = text('TOUCHINGOBJECTMENU');
        if (name == '_mouse_') return s.containsPoint(Offset(mouseX, mouseY));
        if (name == '_edge_') {
          return s.bounds.left < -240 ||
              s.bounds.right > 240 ||
              s.bounds.top < -180 ||
              s.bounds.bottom > 180;
        }
        return sprites.any(
          (other) =>
              other != s &&
              !other.deleted &&
              other.name == name &&
              s.touching(other),
        );
      case 'sensing_of':
        final target = text('OBJECT') == '_stage_'
            ? stage
            : _find(text('OBJECT'));
        if (target == null) return 0;
        final property = _field(b, 'PROPERTY');
        return switch (property) {
          'x position' => target.x,
          'y position' => target.y,
          'direction' => target.direction,
          'costume #' => target.costume + 1,
          'costume name' => target.currentCostume['name'],
          'size' => target.size,
          'volume' => target.volume,
          _ =>
            target.variableNamed(property) ??
                stage.variableNamed(property) ??
                0,
        };
      case 'nkmoremotion_distanceto':
        final dx = n('X') - s.x, dy = n('Y') - s.y;
        return math.sqrt(dx * dx + dy * dy);
      case 'data_lengthoflist':
        return _list(s, _field(b, 'LIST', id: true)).length;
      case 'data_itemoflist':
        final values = _list(s, _field(b, 'LIST', id: true));
        final index = text('INDEX') == 'last'
            ? values.length - 1
            : n('INDEX').toInt() - 1;
        return index >= 0 && index < values.length ? values[index] : '';
      default:
        if (op.endsWith('_menu') ||
            op.contains('_menu_') ||
            [
              'looks_costume',
              'sensing_keyoptions',
              'sensing_touchingobjectmenu',
              'text_menu_twAnimate',
              'motion_goto_menu',
            ].contains(op)) {
          return (b['fields'] as Map).values.first[0];
        }
        unknownOpcodes.add(op);
        return 0;
    }
  }

  String? _sub(Map b, String input) {
    final v = (b['inputs'] as Map?)?[input];
    return v is List && v.length > 1 ? v[1] as String? : null;
  }

  String _blockId(KaguyaSprite s, Map block) =>
      s.blocks.entries.firstWhere((e) => identical(e.value, block)).key;
  static String _field(Map b, String name, {bool id = false}) {
    final v = (b['fields'] as Map?)?[name];
    return v is List && v.isNotEmpty
        ? '${id && v.length > 1 && v[1] != null ? v[1] : v[0]}'
        : '';
  }

  dynamic _variable(KaguyaSprite s, String id) =>
      s.variables[id]?[1] ??
      stage.variables[id]?[1] ??
      s.variableNamed(id) ??
      stage.variableNamed(id) ??
      0;
  void _setVariable(KaguyaSprite s, String id, dynamic value) {
    final variable = s.variables[id] ?? stage.variables[id];
    if (variable != null) variable[1] = value;
  }

  List<dynamic> _list(KaguyaSprite s, String id) =>
      (s.lists[id] ?? stage.lists[id] ?? ['', <dynamic>[]])[1] as List<dynamic>;
  KaguyaSprite? _find(String name) {
    for (final s in sprites) {
      if (!s.isClone && s.name == name) return s;
    }
    return null;
  }

  static double number(dynamic value) {
    if (value is num) return value.toDouble();
    if (value == true) return 1;
    if (value == false) return 0;
    return double.tryParse('$value'.trim()) ?? 0;
  }

  static bool truth(dynamic value) =>
      value != false &&
      value != null &&
      value != 0 &&
      value != '' &&
      value != '0' &&
      '$value'.toLowerCase() != 'false';
  static int compare(dynamic left, dynamic right) {
    final a = double.tryParse('$left'), b = double.tryParse('$right');
    if (a != null && b != null) return a.compareTo(b);
    return '$left'.toLowerCase().compareTo('$right'.toLowerCase());
  }

  void _postgameCycle() {
    setVariableByName('轮回分数', math.max(0, score - _cycleBase));
    if (score >= 10000 && mood > 0) {
      final speed = 8 + math.log(1 + (score - 10000) / 2000) / math.ln2 * 1.35;
      if (number(variableByName('背景速度（我跑步速度')) < speed) {
        setVariableByName('背景速度（我跑步速度', speed);
      }
    }
    if (_cycleAt < 0 && score - _cycleBase >= 10000) {
      final saved = score;
      _cycleBase = saved;
      setVariableByName('关卡轮换中', 1);
      greenFlag(preserveCycle: true);
      _cycleAt = _frame;
    }
    if (_cycleAt >= 0) {
      final elapsed = _frame - _cycleAt;
      if (elapsed == 15) {
        final start = _find('开始游戏');
        if (start != null) {
          start.visible = false;
          for (final t in _threads) {
            if (t.sprite == start) t.dead = true;
          }
        }
        broadcast('游戏开始');
      }
      if (elapsed == 27) {
        setVariableByName('分数', _cycleBase);
        setVariableByName('轮回分数', 0);
      }
      if (elapsed >= 42) {
        setVariableByName('关卡轮换中', 0);
        _cycleAt = -1;
      }
    }
  }

  @override
  void dispose() {
    running = false;
    physics.reset();
    onStopSounds?.call();
    super.dispose();
  }
}

class KaguyaSprite {
  KaguyaSprite(this.source, {this.cloneId = 0}) {
    variables = {
      for (final e in (source['variables'] as Map).entries)
        '${e.key}': List<dynamic>.of(e.value as List),
    };
    lists = {
      for (final e in (source['lists'] as Map).entries)
        '${e.key}': [e.value[0], List<dynamic>.of(e.value[1] as List)],
    };
    x = KaguyaRuntime.number(source['x']);
    y = KaguyaRuntime.number(source['y']);
    size = KaguyaRuntime.number(source['size'] ?? 100);
    direction = KaguyaRuntime.number(source['direction'] ?? 90);
    volume = KaguyaRuntime.number(source['volume'] ?? 100);
    visible = source['visible'] != false;
    costume = (source['currentCostume'] as num?)?.toInt() ?? 0;
    layer = (source['layerOrder'] as num?)?.toInt() ?? 0;
    rotationStyle = '${source['rotationStyle'] ?? 'all around'}';
  }
  final Map<String, dynamic> source;
  final int cloneId;
  String get name => '${source['name']}';
  bool get isStage => source['isStage'] == true;
  bool get isClone => cloneId != 0;
  late final Map<String, dynamic> blocks = Map<String, dynamic>.from(
    source['blocks'] as Map,
  );
  List<Map<String, dynamic>> get costumes =>
      (source['costumes'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get sounds =>
      (source['sounds'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get currentCostume =>
      costumes[costume.clamp(0, costumes.length - 1)];
  late Map<String, List<dynamic>> variables, lists;
  late double x, y, size, direction, volume;
  late bool visible;
  bool deleted = false, physics = false;
  late int costume, layer;
  late String rotationStyle;
  double stretchX = 100,
      stretchY = 100,
      vx = 0,
      vy = 0,
      angularVelocity = 0,
      restitution = .1;
  final effects = <String, double>{};
  Uint8List? masks;
  String text = '',
      font = 'Handwriting',
      textColor = '#575e75',
      outlineColor = '#000000',
      textAnimation = '';
  double fontSize = 24,
      textWidth = 480,
      outlineWidth = 0,
      shake = 0,
      textStarted = 0;
  String displayedText(double time) => textAnimation == 'type'
      ? text.substring(
          0,
          (1 + ((time - textStarted) * 15).floor()).clamp(0, text.length),
        )
      : text;
  bool isTextShaking(double time) =>
      textAnimation == 'shake' &&
      time >= textStarted &&
      time < textStarted + .5;
  dynamic variableNamed(String name) {
    for (final v in variables.values) {
      if (v[0] == name) return v[1];
    }
    return null;
  }

  void switchCostume(dynamic value) {
    final index = costumes.indexWhere((c) => '${c['name']}' == '$value');
    if (index >= 0) {
      costume = index;
    } else {
      costume = (KaguyaRuntime.number(value).toInt() - 1) % costumes.length;
    }
  }

  KaguyaSprite clone(int id) {
    final s = KaguyaSprite(source, cloneId: id);
    s.x = x;
    s.y = y;
    s.size = size;
    s.direction = direction;
    s.volume = volume;
    s.visible = visible;
    s.costume = costume;
    s.layer = layer;
    s.rotationStyle = rotationStyle;
    s.stretchX = stretchX;
    s.stretchY = stretchY;
    s.effects.addAll(effects);
    s.masks = masks;
    s.text = text;
    s.font = font;
    s.textColor = textColor;
    s.textWidth = textWidth;
    s.variables = {for (final e in variables.entries) e.key: List.of(e.value)};
    s.lists = {
      for (final e in lists.entries)
        e.key: [e.value[0], List.of(e.value[1] as List)],
    };
    return s;
  }

  double get angle =>
      rotationStyle == 'all around' ? (direction - 90) * math.pi / 180 : 0;
  double get scaleX =>
      size /
      100 *
      stretchX /
      100 *
      (rotationStyle == 'left-right' && direction < 0 ? -1 : 1);
  double get scaleY => size / 100 * stretchY / 100;
  Offset _worldPoint(double px, double py) {
    final c = currentCostume,
        res = KaguyaRuntime.number(c['bitmapResolution'] ?? 1);
    final dx = (px - KaguyaRuntime.number(c['rotationCenterX'])) / res * scaleX,
        dy = -(py - KaguyaRuntime.number(c['rotationCenterY'])) / res * scaleY;
    return Offset(
      x + dx * math.cos(angle) + dy * math.sin(angle),
      y - dx * math.sin(angle) + dy * math.cos(angle),
    );
  }

  Rect get bounds {
    final c = currentCostume,
        box =
            (c['alphaBounds'] as List?) ??
            [0, 0, c['imageWidth'] ?? 1, c['imageHeight'] ?? 1];
    final points = [
      _worldPoint(KaguyaRuntime.number(box[0]), KaguyaRuntime.number(box[1])),
      _worldPoint(KaguyaRuntime.number(box[2]), KaguyaRuntime.number(box[1])),
      _worldPoint(KaguyaRuntime.number(box[0]), KaguyaRuntime.number(box[3])),
      _worldPoint(KaguyaRuntime.number(box[2]), KaguyaRuntime.number(box[3])),
    ];
    return Rect.fromLTRB(
      points.map((p) => p.dx).reduce(math.min),
      points.map((p) => p.dy).reduce(math.min),
      points.map((p) => p.dx).reduce(math.max),
      points.map((p) => p.dy).reduce(math.max),
    );
  }

  bool containsPoint(Offset point) {
    if (!bounds.contains(point) || scaleX == 0 || scaleY == 0) return false;
    final mask = masks;
    if (mask == null) return true;
    final c = currentCostume;
    final dx = point.dx - x, dy = point.dy - y;
    final res = KaguyaRuntime.number(c['bitmapResolution'] ?? 1);
    final px =
        ((dx * math.cos(angle) - dy * math.sin(angle)) / scaleX * res +
                KaguyaRuntime.number(c['rotationCenterX']))
            .floor();
    final py =
        (-(dx * math.sin(angle) + dy * math.cos(angle)) / scaleY * res +
                KaguyaRuntime.number(c['rotationCenterY']))
            .floor();
    final width = (c['imageWidth'] as num).toInt();
    final height = (c['imageHeight'] as num).toInt();
    if (px < 0 || py < 0 || px >= width || py >= height) return false;
    final bit = py * width + px;
    final offset = (c['maskOffset'] as num).toInt() + (bit >> 3);
    return offset < mask.length && (mask[offset] & (1 << (bit & 7))) != 0;
  }

  bool touching(KaguyaSprite other) {
    // Scratch permits an invisible sensing sprite to query collisions; the
    // candidate drawable itself must be visible. Ghost effects do not erase
    // the costume's collision mask.
    if (!other.visible || deleted || other.deleted) return false;
    final overlap = bounds.intersect(other.bounds);
    if (overlap.isEmpty) return false;
    for (var y = overlap.top.floor(); y < overlap.bottom.ceil(); y++) {
      for (var x = overlap.left.floor(); x < overlap.right.ceil(); x++) {
        final point = Offset(x + .5, y + .5);
        if (containsPoint(point) && other.containsPoint(point)) return true;
      }
    }
    return false;
  }
}

class _Thread {
  _Thread(this.sprite, this.hat, this.pc);
  final KaguyaSprite sprite;
  final String hat;
  String? pc;
  final stack = <_Frame>[];
  double until = 0;
  bool dead = false, yielded = false;
  int warpDepth = 0;
  List<_Thread>? waiting;
  _Tween? tween;
}

class _Frame {
  _Frame(this.kind, this.body, this.next, this.count, this.block);
  final String kind;
  final String? body, next;
  int count;
  final Map? block;
}

class _Tween {
  _Tween(
    this.start,
    this.seconds,
    this.x,
    this.y,
    this.toX,
    this.toY,
    this.mode,
    this.direction,
  );
  final double start, seconds, x, y, toX, toY;
  final String mode, direction;
}
